# Basic Navigation: pwd, cd, ls, mkdir, rmdir, touch, cp, mv, rm

The commands you'll type more than any others — and the flags/gotchas that separate "knows Linux" from "has used Linux."

## Explanation

These commands manipulate the filesystem tree directly through syscalls (`getcwd()`, `chdir()`, `mkdir()`, `rename()`, `unlink()`, etc.) — there's no magic here, just thin wrappers over kernel filesystem operations. Getting comfortable with their flags is less about memorization and more about internalizing a few mechanical facts that explain *all* the gotchas.

### `pwd` — print working directory
Prints the shell's current working directory. Every process (not just shells) has a current working directory tracked by the kernel; relative paths (`./file`, `../dir`) are always resolved against it. `pwd -P` resolves symlinks and prints the physical path; plain `pwd` (and the `$PWD` shell variable) can reflect the logical, symlinked path you `cd`'d through.

### `cd` — change directory
A **shell builtin**, not an external program (it has to be — a separate process can't change its parent shell's working directory). Key idioms: `cd -` returns to the previous directory (toggles between two), `cd` with no args goes to `$HOME`, `cd ~user` goes to another user's home directory.

### `ls` — list directory contents
Bare `ls` hides dotfiles (anything starting with `.`) by default. Critical flags: `-l` (long format: permissions, owner, group, size, mtime), `-a` (show all, including `.`/`..`/dotfiles), `-h` (human-readable sizes with `-l`), `-t` (sort by modification time, newest first), `-S` (sort by size), `-R` (recursive), `-d` (list the directory itself, not its contents — crucial for `ls -ld /some/dir` to see a directory's own permissions).

### `mkdir` / `rmdir` — create / remove directories
`mkdir -p` creates parent directories as needed AND doesn't error if the target already exists — the standard flag you always want in scripts (`mkdir /a/b/c` fails if `/a/b` doesn't exist; `mkdir -p /a/b/c` just makes the whole chain). `rmdir` only removes **empty** directories — this is a safety feature, not a limitation; for non-empty directories you need `rm -r`.

### `touch` — create empty files / update timestamps
If the file doesn't exist, `touch` creates an empty one. If it *does* exist, `touch` just updates its modification (and access) timestamp to now, without changing content — this second behavior is the actually-common real-world use (e.g., forcing a rebuild trigger, or `touch`-ing a flag file another process polls for).

### `cp` — copy files/directories
Plain `cp` only copies regular files; `cp -r` (recursive) is required for directories. `cp -p` preserves mode/ownership/timestamps. `cp -a` (archive) is the "just preserve everything, recurse, don't follow symlinks" combo flag — the one to reach for when cloning a directory tree faithfully. Trailing-slash behavior matters: `cp -r src dest/` where `dest/` exists copies `src` *into* `dest`; if `dest` doesn't exist, `src`'s contents become `dest` itself.

### `mv` — move/rename
There's no real distinction between "move" and "rename" at the command level — moving within the same filesystem is a cheap metadata-only rename (`rename()` syscall); moving across filesystems (e.g., `/` to a different mounted disk) is actually a copy-then-delete under the hood, which is why it's slower and why interrupted cross-filesystem moves can leave partial data.

### `rm` — remove files/directories
`rm` deletes files; `rm -r` recurses into directories; `rm -f` suppresses prompts/errors (including "file doesn't exist"). **`rm -rf` is genuinely dangerous** — it has no undo, doesn't ask, and doesn't check whether you meant it. There is no "trash" on the command line by default (unlike a GUI file manager).

### Which flags should you actually reach for by default? (Decision rule)

| Task | Reach for | Why |
|---|---|---|
| Creating a nested directory path | `mkdir -p` | Always, even for one level — avoids "no such file or directory" errors and is idempotent |
| Copying a directory tree | `cp -a` | Preserves permissions/timestamps/symlinks correctly; plain `cp -r` can silently follow symlinks or reset permissions |
| Deleting anything non-trivial | `rm -i` interactively, plain `rm -rf` only in scripts you've tested | `-i` prompts per file — worth the friction on a production box; scripts should be tested against a dry-run path first, since `-f` suppresses every safety net |
| Listing to actually understand a directory | `ls -la` | You almost always want to see hidden files/dotfiles and full metadata, not the bare default |
| Checking a directory's OWN permissions (not its contents) | `ls -ld dirname` | Without `-d`, `ls -l dirname` lists the *contents* of the directory, not the directory entry itself — a very common mistake |

**Bottom line: default to the "safe/complete" variant of each command (`-p`, `-a`, `-la`, `-ld`) — the extra characters cost nothing and prevent an entire class of "why didn't this work" confusion; only drop to the bare form when you have a specific reason not to.**

## Hands-On Examples

**1. `pwd` and `cd` basics, including `cd -`**
```bash
$ pwd
/home/deepak

$ cd /var/log
$ pwd
/var/log

$ cd -
/home/deepak
$ pwd
/home/deepak
```

**2. `ls` — default vs the flags you actually want**
```bash
$ ls
app.log  config.yml  scripts

$ ls -la
total 24
drwxr-xr-x  4 deepak deepak 4096 Aug  8 09:12 .
drwxr-xr-x 18 deepak deepak 4096 Aug  8 08:00 ..
-rw-r--r--  1 deepak deepak  512 Aug  8 09:10 .env
-rw-r--r--  1 deepak deepak 2048 Aug  8 09:12 app.log
-rw-r--r--  1 deepak deepak  184 Aug  7 14:22 config.yml
drwxr-xr-x  2 deepak deepak 4096 Aug  6 10:00 scripts

$ ls -ld scripts
drwxr-xr-x 2 deepak deepak 4096 Aug  6 10:00 scripts
# vs without -d, this would list scripts' CONTENTS, not this permission line
```

**3. `mkdir -p` — the idempotent, no-error-on-existing pattern**
```bash
$ mkdir new_project/src
mkdir: cannot create directory 'new_project/src': No such file or directory

$ mkdir -p new_project/src
$ mkdir -p new_project/src        # run again — no error, nothing breaks
$ ls new_project
src
```

**4. `touch` — creating vs updating timestamps (a genuinely common ops pattern)**

Multi-line commands typed directly at an interactive prompt make bash print a `>` continuation prompt automatically on every line until the command is complete — you never type the `>` yourself, bash is just signaling "still waiting for more input." The example below shows this for a `for` loop, then the same logic saved in a script file (no `>` prefix at all).

```bash
$ for env in dev staging prod; do
>     touch "/tmp/deploy-flags/${env}.ready"
> done
$ ls -l /tmp/deploy-flags/
-rw-r--r-- 1 deepak deepak 0 Aug  8 09:20 dev.ready
-rw-r--r-- 1 deepak deepak 0 Aug  8 09:20 prod.ready
-rw-r--r-- 1 deepak deepak 0 Aug  8 09:20 staging.ready
```
Saved as a script file (`make_flags.sh`), the exact same logic has no `>` characters at all:
```bash
#!/bin/bash
for env in dev staging prod; do
    touch "/tmp/deploy-flags/${env}.ready"
done
```
```bash
$ touch dev.ready       # existing file — content untouched, mtime updated
$ stat -c '%y' dev.ready
2026-08-08 09:25:11.000000000 +0000
```

**5. `cp` — trailing-slash / directory-target behavior, and `-a` for faithful cloning**
```bash
$ cp -r configs/ configs_backup
$ ls configs_backup
nginx.conf  app.yml

$ cp -a /etc/myapp /opt/myapp_snapshot
$ diff -r /etc/myapp /opt/myapp_snapshot
# no output = identical, including permissions/timestamps thanks to -a
```

**6. `mv` — rename vs cross-filesystem move (and why the latter is slower)**
```bash
$ mv report_draft.txt report_final.txt      # same filesystem: instant metadata rename
$ ls
report_final.txt

$ df -h /home /mnt/external
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda2        80G   45G   31G  60% /home
/dev/sdb1       500G  120G  380G  24% /mnt/external

$ time mv large_backup.tar.gz /mnt/external/
real    0m4.812s        # crosses filesystems -> actual copy+delete, not instant
```

**7. `rm` — the dangerous defaults, and safer real-world habits**
```bash
$ rm old_report.txt
$ rm nonexistent_file.txt
rm: cannot remove 'nonexistent_file.txt': No such file or directory

$ rm -f nonexistent_file.txt      # -f suppresses the "doesn't exist" error too — silent by design
$ echo $?
0

$ rm -ri old_builds/
rm: descend into directory 'old_builds'? y
rm: remove regular file 'old_builds/v1.tar.gz'? y
rm: remove regular file 'old_builds/v2.tar.gz'? n
```

**8. Real-world: a safe cleanup script pattern using `find` + these primitives**
```bash
$ cat cleanup_old_logs.sh
#!/bin/bash
LOG_DIR="/var/log/myapp"
DAYS_OLD=30
mkdir -p "$LOG_DIR/archive"
find "$LOG_DIR" -maxdepth 1 -name "*.log" -mtime +$DAYS_OLD -print
# ^ dry-run first: ALWAYS see what would be deleted before adding -delete or piping to rm
```
```bash
$ ./cleanup_old_logs.sh
/var/log/myapp/access-2026-06-01.log
/var/log/myapp/access-2026-06-02.log
```
The senior-level habit here: never run `rm` blind on a glob or `find` result in production — print/dry-run first, confirm the list, *then* execute the destructive step.

## Practice Questions

1. What's the difference between `mkdir foo/bar` and `mkdir -p foo/bar` when `foo` doesn't exist yet? Why is `-p` the safer default for scripts?
2. Why does `rmdir` refuse to remove a non-empty directory, and what command would you use instead?
3. You run `ls -l some_directory` expecting to see that directory's own permission bits, but instead you see a list of files inside it. What flag fixes this, and why does the behavior differ?
4. What actually happens on disk when you `mv` a file within the same filesystem versus across two different mounted filesystems? Why is one nearly instant and the other slow for large files?
5. Explain what `touch existing_file.txt` does. Why is this behavior — as opposed to erroring, or truncating the file — actually useful in real scripts?
6. Why is `cd` implemented as a shell builtin rather than an external program like `/bin/ls`?
7. What's the practical difference between `cp -r` and `cp -a`? Give a scenario where `-r` alone would produce a subtly wrong copy.
8. You accidentally run `rm -rf` on the wrong directory in production. What, if anything, can be done afterward, and what practice would have prevented this incident from being catastrophic (hint: think about dry-runs, backups, and `-i`)?
9. What does `cd -` do, and how is it different from `cd ~` or `cd $HOME`?
10. Write a one-liner using `find` (dry-run, no deletion yet) to list all `.tmp` files older than 7 days under `/var/tmp`, before eventually piping that into a deletion step.

## Real Interview Questions (Company-Attributed)

- "What is the difference between a hard link and a soft link?" — asked at *IBM, Morgan Stanley, Qentelli Solutions, Verizon*
- "What is the Linux command to create a soft link?" — asked at *Morgan Stanley*

## Interview Key Points

- **`rm -rf` has no undo** — always frame answers about deletion with a dry-run-first mindset (`find ... -print` before `find ... -delete`, or `ls` the glob before `rm` it); this instinct is exactly what interviewers are listening for on any deletion-related question.
- **`mkdir -p` is idempotent and safe to always use** — know this as a default habit, not a special-case flag; scripts that use bare `mkdir` and don't handle the "already exists" error are a common code-review flag.
- **`cd` must be a shell builtin** — a classic "why can't an external program change my shell's directory" conceptual question; the answer hinges on process/child relationships (a child process can't mutate its parent's environment/cwd).
- **`cp -r` vs `cp -a`** — `-a` (archive) preserves permissions, ownership, timestamps, and symlinks; plain `-r` can silently normalize permissions or dereference symlinks — worth naming as the "correct" flag for faithful directory cloning.
- **Same-filesystem `mv` is a metadata-only rename (fast); cross-filesystem `mv` is copy+delete (slow, and can leave partial state if interrupted)** — a good "do you understand what's happening under the hood" answer.
- `touch` on an existing file only updates timestamps, doesn't touch content — commonly used in real automation as a lightweight signal/flag-file mechanism (e.g., "job finished" markers polled by another process).
- `ls -ld` vs `ls -l` on a directory — one of the most common "gotcha, did you actually use this command a lot" checks; get this backwards and it signals limited hands-on time.
- Trailing-slash semantics in `cp`/`mv` (copying *into* an existing directory vs. *as* a new directory name) is a subtle, real source of bugs in automation scripts — worth mentioning if the conversation goes deep on `cp`/`mv`.

Sources:
- [Basic Linux Commands - GeeksforGeeks](https://www.geeksforgeeks.org/linux-unix/basic-linux-commands/)
- [50+ Essential Linux Commands: A Comprehensive Guide - DigitalOcean](https://www.digitalocean.com/community/tutorials/linux-commands)
- [96 Linux Commands interview questions (and answers) - Adaface](https://www.adaface.com/blog/linux-commands-interview-questions/)
- [Top 35 Linux Commands Interview Questions With Answers - Testbook](https://testbook.com/interview/linux-commands-interview-questions)
