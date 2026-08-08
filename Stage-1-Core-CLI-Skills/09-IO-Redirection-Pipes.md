# I/O Redirection & Pipes (`>`, `>>`, `<`, `|`, `2>`, `2>&1`, `tee`)

Every process talks to the world through three numbered file descriptors, and redirection is just the shell rewiring those numbers before the program ever runs — get the mechanics wrong and you silently lose logs, leak secrets to a terminal, or overwrite data you meant to keep.

## Explanation

### The three standard file descriptors

Every process starts with three open file descriptors, small integers the kernel tracks per-process:

- **`0` = stdin** (standard input) — normally the keyboard/terminal
- **`1` = stdout** (standard output) — normally the terminal
- **`2` = stderr** (standard error) — also normally the terminal, kept *separate* from stdout on purpose so error messages can be told apart from normal output

These are not "streams" in some abstract sense — they are literal entries in the process's file descriptor table, each pointing at an open file (which can be a terminal device, a regular file, a pipe, or `/dev/null`). Redirection operators (`>`, `<`, `2>&1`, etc.) are parsed and applied **by the shell**, *before* it execs the target program. The command itself never sees `>` or `2>&1` — by the time it starts running, its fd 0/1/2 already point wherever the shell set them up to point, and the program just writes to "fd 1" oblivious to whether that's a terminal, a file, or a pipe.

### `>` and `>>` — output redirection

```bash
cmd > file     # OVERWRITE: truncates file to 0 bytes first, then writes (creates file if missing)
cmd >> file    # APPEND: writes are added to the end, existing content preserved
```

The `>` gotcha is one of the most common real-world mistakes: running `cmd > file.log` a second time (e.g., a cron job, a re-run script) when you meant `>>` **silently destroys everything previously in the file** — there is no warning, no confirmation. `>` truncates immediately, even before the command produces any output (so `somecommand-that-fails > file` still empties `file`).

### `<` — input redirection

```bash
cmd < file     # cmd reads its stdin from file's contents instead of the keyboard/pipe
```

Useful for feeding a command a file directly instead of `cat file | cmd`.

### `2>` — redirecting stderr only

```bash
cmd 2> errors.log     # stderr goes to errors.log; stdout still goes to the terminal (or wherever it was)
```

This is the key to isolating error messages from normal output — stdout is untouched.

### `2>&1` and the ordering rule

`2>&1` means **"make file descriptor 2 point to wherever file descriptor 1 currently points, right now"** — it is a one-time copy of a target, not a permanent link between the two descriptors. Redirections are parsed and applied **left to right**, so *where 1 is currently pointing when the shell reaches `2>&1`* is everything.

```bash
command > file 2>&1     # CORRECT for "send both stdout and stderr to file"
command 2>&1 > file     # WRONG for that same intent
```

Walk through both left to right:

1. `command > file 2>&1`
   - `> file`: fd 1 now points at `file`.
   - `2>&1`: fd 2 is set to point at *whatever fd 1 currently points to* — which is now `file`.
   - Result: both stdout and stderr end up in `file`. Correct.

2. `command 2>&1 > file`
   - `2>&1`: fd 2 is set to point at *whatever fd 1 currently points to* — at this moment, fd 1 still points at the terminal.
   - `> file`: fd 1 is *then* redirected to `file`.
   - Result: stderr still points at the terminal (it copied fd 1's target *before* fd 1 moved), stdout now goes to `file`. Errors print on screen and never reach the file — almost never what you wanted.

### `&>` and `&>>` — bash shorthand

```bash
cmd &> file      # equivalent to: cmd > file 2>&1
cmd &>> file     # equivalent to: cmd >> file 2>&1
```

Bash/zsh-specific convenience syntax, not POSIX — a `#!/bin/sh` script running under `dash` won't understand `&>`, so prefer the portable `> file 2>&1` form in scripts meant to be POSIX-compatible.

### `|` — pipes only carry stdout

```bash
cmd1 | cmd2      # cmd1's stdout is connected directly to cmd2's stdin, via an in-kernel pipe buffer
```

Critically: **a pipe only wires up fd 1 (stdout) of the left command to fd 0 (stdin) of the right command.** fd 2 (stderr) of the left command is left completely alone and keeps going to the terminal. This surprises people constantly — `noisy_cmd | grep foo` still prints `noisy_cmd`'s error messages to your screen even though its normal output is being piped away. To pipe stderr too, merge it into stdout *before* the pipe: `noisy_cmd 2>&1 | grep foo`.

### `tee` — split one stream into two destinations

`tee` reads from stdin and writes the exact same bytes to **both** stdout (so a pipeline can continue) **and** to one or more files, simultaneously. It's the tool for "I want to watch this live *and* keep a copy," which plain `>` can't do (that only keeps the copy, nothing shown).

```bash
cmd | tee file.log            # cmd's output: shown on screen AND saved to file.log (overwrite)
cmd | tee -a file.log         # same, but append to file.log instead of truncating
cmd | tee file1.log file2.log # write to multiple files at once
```

`tee /dev/tty` is a trick for forcing output to the actual terminal even in contexts where stdout has been redirected elsewhere in the pipeline — useful for debugging deep in a chain of pipes.

### Redirection order and the sudo-echo trap (Decision rule / gotchas to memorize)

**Rule 1 — `2>&1` placement:** put `2>&1` **after** the `>` target when your goal is "send both streams to the same file." `cmd > file 2>&1` is right; `cmd 2>&1 > file` leaks stderr to the terminal. Mental model: `2>&1` copies a target, it doesn't create a permanent bond — read redirections strictly left to right and track what fd 1 points to *at that instant*.

**Rule 2 — the `sudo echo` / `sudo cmd > file` trap:** `sudo echo "text" > /etc/some-root-owned-file` almost always fails with "Permission denied" even though `sudo` is right there. Why: `sudo` only elevates privileges for the *command it runs* (`echo`, in this case) — but the `> file` redirection is set up by **your current, unprivileged shell**, *before* `sudo` even starts `echo`. The shell — not root — is the one trying (and failing) to open `/etc/some-root-owned-file` for writing. The fix is to give `tee` the privilege instead, since `tee` (not the shell) is the process that opens the file: `echo "text" | sudo tee /etc/some-root-owned-file > /dev/null` (the trailing `> /dev/null` just silences tee's normal stdout echo of what it wrote, if you don't want it printed twice).

### `/dev/null` — the black hole

Writing to `/dev/null` discards data; reading from it returns EOF instantly. Used to silence unwanted output:

```bash
cmd > /dev/null           # discard stdout, still show stderr
cmd 2> /dev/null          # discard stderr, still show stdout
cmd > /dev/null 2>&1      # discard both (order matters here too — same rule as above)
cmd &> /dev/null          # bash shorthand for the same "discard everything"
```

### One related feature, briefly

Process substitution, `<(command)`, lets a command's output be treated as if it were a temporary file path (e.g. `diff <(sort a.txt) <(sort b.txt)`) — a distinct, more advanced mechanism from simple redirection, not the focus here.

## Hands-On Examples

**1. `>` truncates — the classic accidental data-loss demo**
```bash
$ echo "line 1" > notes.txt
$ echo "line 2" > notes.txt
$ cat notes.txt
line 2
```
The second `>` silently wiped `line 1`. Compare with `>>`:
```bash
$ echo "line 1" > notes.txt
$ echo "line 2" >> notes.txt
$ cat notes.txt
line 1
line 2
```

**2. `2>` isolates stderr from stdout**
```bash
$ ls /etc/passwd /nonexistent_dir 2> errors.log
/etc/passwd
$ cat errors.log
ls: cannot access '/nonexistent_dir': No such file or directory
```
`ls`'s normal output for the file that exists still prints to the terminal; only the error line went to `errors.log`.

**3. `2>&1` order matters — both orderings, side by side**
```bash
$ ls /etc/passwd /nope > result.log 2>&1
$ cat result.log
/etc/passwd
ls: cannot access '/nope': No such file or directory
```
Both lines landed in the file — correct.
```bash
$ ls /etc/passwd /nope 2>&1 > result2.log
ls: cannot access '/nope': No such file or directory
$ cat result2.log
/etc/passwd
```
The error printed straight to the terminal instead of going into `result2.log` — only the normal output made it into the file, because `2>&1` copied stdout's target (the terminal) *before* `> result2.log` moved stdout away.

**4. A pipe does not carry stderr**
```bash
$ find /etc /nonexistent_path -name "*.conf" | grep host
find: '/nonexistent_path': No such file or directory
/etc/hostname
/etc/hosts
```
`find`'s error line still appears on the terminal even though its normal output is piped into `grep` — the pipe only forwarded stdout. To pipe the error too:
```bash
$ find /etc /nonexistent_path -name "*.conf" 2>&1 | grep -i "no such"
find: '/nonexistent_path': No such file or directory
```

**5. `tee` — watch a build live while saving the log**
```bash
$ npm run build 2>&1 | tee build.log
> myapp@1.0.0 build
> webpack --mode production
asset main.js 142 KiB [emitted] [minimized]
webpack compiled successfully in 3421 ms
$ tail -1 build.log
webpack compiled successfully in 3421 ms
```
Output shows up on screen in real time *and* the full transcript is saved — merging stderr first with `2>&1` before `tee` ensures build warnings/errors get captured too, not just stdout.

**6. `tee -a` appending across multiple runs**
```bash
$ date | tee -a deploy-history.log
Sat Aug  8 10:02:15 UTC 2026
$ date | tee -a deploy-history.log
Sat Aug  8 10:14:47 UTC 2026
$ cat deploy-history.log
Sat Aug  8 10:02:15 UTC 2026
Sat Aug  8 10:14:47 UTC 2026
```

**7. The `sudo tee` trick for a root-owned config file**
```bash
$ sudo echo "127.0.0.1 internal.svc" >> /etc/hosts
bash: /etc/hosts: Permission denied

$ echo "127.0.0.1 internal.svc" | sudo tee -a /etc/hosts
127.0.0.1 internal.svc
$ tail -1 /etc/hosts
127.0.0.1 internal.svc
```
The first form fails because the unprivileged shell owns the redirection; the second works because `tee` — the process that actually opens `/etc/hosts` — is the one running as root.

**8. Production pattern: timestamped combined log via `&>`**
```bash
$ cat > deploy.sh << 'EOF'
#!/bin/bash
LOGFILE="/var/log/deploy_$(date +%Y%m%d_%H%M%S).log"
{
  echo "Starting deploy at $(date)"
  systemctl restart myapp
  echo "Deploy finished at $(date)"
} &> "$LOGFILE"
echo "Log written to $LOGFILE"
EOF
$ ./deploy.sh
Log written to /var/log/deploy_20260808_101530.log
$ cat /var/log/deploy_20260808_101530.log
Starting deploy at Sat Aug  8 10:15:30 UTC 2026
Deploy finished at Sat Aug  8 10:15:31 UTC 2026
```
Grouping commands in `{ ... }` and redirecting once with `&>` captures both streams from every command inside the block into a single timestamped file, without repeating `2>&1` on each line.

## Practice Questions

1. What are file descriptors 0, 1, and 2, and at what point (shell vs. exec'd program) does redirection actually get applied?
2. You run `cmd > out.log` twice in a row expecting the second run's output to be added to the first. What actually happens to `out.log`, and how would you fix the command?
3. Spot the bug: a teammate writes `myscript.sh 2>&1 > combined.log` intending to capture both stdout and stderr in `combined.log`, but errors keep showing up on the terminal instead. Explain exactly why, and give the corrected command.
4. Explain the mental model for `2>&1` — why is it described as "point fd 2 at wherever fd 1 currently points" rather than "permanently link fd 2 and fd 1"?
5. A teammate runs `sudo echo "nameserver 8.8.8.8" > /etc/resolv.conf` and gets "Permission denied" despite using `sudo`. Why does this fail, and what's the correct one-liner using `tee` to fix it?
6. Given `noisy_build_tool | grep -i error`, why might you still see `noisy_build_tool`'s error output on your terminal even though you're grepping its output? How do you fix the pipeline so `grep` also sees the error text?
7. What does `tee -a` do differently from plain `tee`, and when would `tee /dev/tty` inside a longer pipeline be useful?
8. Write a command that runs a backup script, shows its output live on screen, and also saves both stdout and stderr into `/var/log/backup.log` in append mode.
9. What's the difference between `&>` / `&>>` and `> file 2>&1` / `>> file 2>&1`? Why might you avoid `&>` in a script that starts with `#!/bin/sh`?
10. You need to completely silence a noisy command — no stdout, no stderr, nothing printed. Write the command, and explain what `/dev/null` actually does when written to.

## Real Interview Questions (Company-Attributed)

- "What are stdin, stdout, and stderr in Linux?" — asked at *Morgan Stanley*

## Interview Key Points

- Every process starts with fd 0 (stdin), fd 1 (stdout), fd 2 (stderr) — redirection is the **shell** rewiring these integers before it execs the command, not something the program itself parses.
- `>` truncates on open (data loss risk if you meant `>>`); `>>` appends; know this distinction cold, it's the most basic trap in the topic.
- **`2>&1` ordering rule, stated crisply**: it must come *after* the `>` target to merge both streams into a file (`cmd > file 2>&1`), because `2>&1` copies whatever fd 1 currently points to — putting it before `> file` merges stderr into the *old* stdout target (the terminal), not the file.
- **Pipes only carry stdout by default** — a piped command's stderr still goes straight to the terminal unless you explicitly `2>&1` before the `|` to merge the streams first.
- `tee` writes to stdout *and* a file simultaneously (`-a` to append) — the standard tool for "watch it live and keep a log"; the `sudo tee` pattern (`echo x | sudo tee file`) exists because `sudo cmd > file` fails — the redirection is performed by the calling shell (unprivileged), not by the sudo'd command, so `sudo` never gets a chance to elevate the file-open itself.
- `/dev/null` discards anything written to it; `cmd > /dev/null 2>&1` (or `cmd &> /dev/null` in bash) is the standard idiom for fully silencing a command.
- `&>`/`&>>` are bash/zsh convenience shorthands for `> file 2>&1` / `>> file 2>&1` — not POSIX, avoid in portable `/bin/sh` scripts.
- Interviewers use this topic specifically to probe whether you understand file descriptors as kernel-tracked integers (not "streams" you can wave hands at) — the `2>&1` ordering question and the `sudo echo` trap are the two highest-frequency "gotcha" questions asked in practice.
