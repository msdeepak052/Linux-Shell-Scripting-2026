# Here-Docs (`<<EOF`) and Process Substitution (`<(...)`, `>(...)`)

Two mechanisms for feeding multi-line text or another command's output into a command as if it were a file — essential for templating configs and avoiding the classic "pipe into a while loop loses my variables" bug.

## Explanation

### Here-docs — inline multi-line input

```bash
command << DELIMITER
line 1
line 2
DELIMITER
```
`DELIMITER` (commonly `EOF`, but any unique token works) marks where the block ends — it must appear alone on its own line, unindented, unless you use `<<-` (see below). Key variants:

- **`<<EOF` (unquoted delimiter)** — bash performs variable expansion, command substitution, and backslash escapes inside the block, just like a double-quoted string.
- **`<<'EOF'` (quoted delimiter)** — bash treats the block as **completely literal**, no expansion at all. Critical when the heredoc content itself contains `$` signs you don't want interpreted (e.g., writing a script that contains `$1`, or a template with literal `$VAR` placeholders meant for another program to expand).
- **`<<-EOF`** — allows the closing delimiter (and only the closing delimiter's *detection*, not the body) to be indented with **tab characters** (not spaces) so the heredoc can be nested inside an indented block of script and still read cleanly. Leading tabs are stripped from the body lines too.
- **`<<< "string"` (here-string)** — a one-line cousin: feeds a single string as stdin without the multi-line block syntax at all. `command <<< "$var"` is the concise equivalent of `echo "$var" | command`, minus spawning an extra `echo` process.

### Process substitution — treat a command's output (or input) as a file

```bash
<(command)     # command's STDOUT is exposed as a readable "file path" (usually /dev/fd/N)
>(command)     # a "file path" that, when written to, feeds command's STDIN
```
Mechanically, bash runs `command` in the background, connects it to a FIFO (named pipe) or `/proc/self/fd` entry, and substitutes that path in place of `<(...)`/`>(...)` in the outer command line. The outer command sees what looks like an ordinary file path — many programs that only accept file arguments (not stdin) can be fed live command output this way.

**The big practical win**: process substitution runs the substituted command **without** putting the *outer* command in a subshell — unlike a pipe. This matters enormously for the classic bug:
```bash
count=0
cat file.txt | while read -r line; do count=$((count+1)); done
echo "$count"   # prints 0! the while loop ran in a subshell (piped), its variable changes didn't survive
```
vs.
```bash
count=0
while read -r line; do count=$((count+1)); done < <(cat file.txt)
echo "$count"   # correct — no pipe, no subshell, count survives
```

### Which one should you actually use? (Decision rule)

| Need | Use | Why |
|---|---|---|
| Feed a fixed multi-line block of text/config to a command | Here-doc (`<<EOF`) | Purpose-built, readable, supports variable expansion when wanted |
| Feed one single value/line | Here-string (`<<< "$var"`) | Simpler than a heredoc or an extra `echo \| ` pipe for one line |
| Compare two command outputs as if they were files (e.g. `diff`) | Process substitution `<(...)` | Lets `diff`/`comm` (which expect file args) work directly on command output, no temp files |
| Read a file/command output into a `while read` loop and KEEP variables set inside the loop | Process substitution `< <(...)` | Avoids the pipe-creates-a-subshell variable-loss bug |
| Send one stream to multiple consumers (e.g., log to a file AND grep it live) | Process substitution `>(...)`, often with `tee` | `tee >(cmd1) >(cmd2)` fans a stream out to N sinks in parallel |

**Bottom line: use here-docs for static/templated multi-line text, here-strings for single values, and process substitution whenever you need a command's output to behave like a file argument OR need a piped loop's variables to survive outside the loop.**

## Hands-On Examples

**1. Basic here-doc — feeding a script into `cat`**
```bash
$ cat << EOF
Deployment starting at $(date '+%H:%M:%S')
Target environment: production
EOF
Deployment starting at 14:32:07
Target environment: production
```
Unquoted `EOF` means `$(date ...)` is expanded — exactly like double quotes would.

**2. Quoted delimiter — suppressing expansion entirely**
```bash
$ cat << 'EOF'
This literal $HOME and $(whoami) will NOT be expanded.
EOF
This literal $HOME and $(whoami) will NOT be expanded.
```
Essential when generating a script or template that should contain literal `$VAR` for some *other* program to interpret later — e.g., writing out a `.env.template` file or a script that itself uses `$1`.

**3. `<<-` for indented heredocs inside a function**
```bash
$ cat > deploy.sh << 'OUTER'
deploy() {
	if [[ "$1" == "prod" ]]; then
		cat <<- EOF
			Deploying to PRODUCTION
			Confirm with --yes flag
		EOF
	fi
}
deploy prod
OUTER
$ bash deploy.sh
Deploying to PRODUCTION
Confirm with --yes flag
```
The `<<-` variant strips leading **tabs** (not spaces) from both the body and the closing `EOF`, letting the heredoc's indentation visually match the surrounding code block instead of forcing it flush against the left margin.

**4. Here-string — feeding one value without an extra process**
```bash
$ read -r first last <<< "Deepak Yadav"
$ echo "First: $first, Last: $last"
First: Deepak, Last: Yadav

$ grep -o '[0-9]\+' <<< "server-42-east"
42
```
Equivalent to `echo "server-42-east" | grep -o '[0-9]\+'` but without spawning `echo` as a separate process — a small efficiency win, and cleaner to read for one-off single-value input.

**5. Process substitution with `diff` — comparing command output as if it were files**
```bash
$ diff <(ssh web-01 "dpkg -l | awk '{print \$2,\$3}'") <(ssh web-02 "dpkg -l | awk '{print \$2,\$3}'")
2c2
< openssl 3.0.2-0ubuntu1.10
---
> openssl 3.0.2-0ubuntu1.15
15c15
< nginx 1.18.0-6ubuntu14.4
---
> nginx 1.18.0-6ubuntu14.3
```
This is a genuinely common ops task — comparing installed package versions across two hosts — done with **zero temp files**, because `<(...)` gives `diff` two "files" that are actually live SSH command output.

**6. Process substitution to fix the classic `while read` subshell bug**
```bash
$ cat servers.txt
web-01
web-02
db-01

$ failed=0
$ while read -r host; do
>     ping -c1 -W1 "$host" &>/dev/null || failed=$((failed+1))
> done < <(cat servers.txt)
$ echo "Unreachable hosts: $failed"
Unreachable hosts: 1
```
Because `< <(cat servers.txt)` redirects input (not a pipe), the `while` loop runs in the **current shell**, not a subshell — so `failed` correctly retains its incremented value after the loop ends. Had this been written as `cat servers.txt | while read -r host; do ...; done`, `$failed` would print `0` regardless of what happened inside the loop.

**7. Output process substitution `>(...)` — fanning one stream to multiple sinks**
```bash
$ tail -f app.log | tee >(grep --line-buffered ERROR >> errors.log) \
                        >(grep --line-buffered WARN  >> warnings.log) \
                        > /dev/null &
[1] 48213
$ echo "New request failed" >> app.log
$ echo "ERROR: disk full on /data" >> app.log
$ cat errors.log
ERROR: disk full on /data
```
`tee` writes its input to every argument given, including `>(...)` process substitutions — here it fans live log lines into two separate filtered files (`errors.log`, `warnings.log`) concurrently, without writing three separate `grep` passes over the whole file or juggling temp FIFOs manually.

**8. A realistic combined example — validating a config template before applying it**
```bash
$ cat > render_config.sh << 'EOF'
#!/bin/bash
set -euo pipefail
env_name="${1:?usage: render_config.sh <env>}"

diff <(cat /etc/myapp/config.yml.template) \
     <(sed "s/{{ENV}}/${env_name}/" /etc/myapp/config.yml.template) \
     && echo "No placeholders were substituted — check the template" \
     || echo "Diff shown above: rendered output differs from the raw template, as expected"
EOF
$ chmod +x render_config.sh
$ ./render_config.sh production
1c1
< environment: {{ENV}}
---
> environment: production
Diff shown above: rendered output differs from the raw template, as expected
```
A quick sanity check pattern: diff the raw template against its rendered form via process substitution to confirm a substitution actually took effect, before writing the rendered file anywhere permanent.

## Practice Questions

1. What's the difference between `cat << EOF` and `cat << 'EOF'`? Give a concrete example where using the wrong one causes a bug.
2. Why does `<<-EOF` require tabs (not spaces) for the indentation-stripping to work, and what happens if you indent with spaces instead?
3. A script does `count=0; find . -name "*.log" | while read -r f; do count=$((count+1)); done; echo "$count"` and always prints `0`. What's wrong, and how do you fix it using process substitution?
4. Explain mechanically what `<(command)` actually is under the hood — what does bash substitute in its place on the command line?
5. Write a one-liner using `diff` and process substitution to compare the output of `sort file1.txt` against `sort file2.txt` without creating any temp files.
6. What does `tee >(grep ERROR > err.log) >(grep WARN > warn.log)` accomplish, and why is `tee` needed here rather than just piping to one of the process substitutions directly?
7. When would you use a here-string (`<<<`) instead of a here-doc (`<<EOF`)? Rewrite `printf '%s' "$var" | wc -l` using a here-string.
8. Does process substitution (`<(...)`) work in POSIX `/bin/sh`, or is it bash/ksh/zsh-specific? Why does this matter for a script's shebang line?
9. Write a heredoc that generates a temporary SQL script and pipes it into a `psql` command, substituting a shell variable for a table name.

## Interview Key Points

- **`<<EOF` (unquoted) expands variables/command substitution; `<<'EOF'` (quoted) does not** — exactly like the double-quote vs single-quote distinction elsewhere in bash; a very common "spot the bug" question when a heredoc's `$VAR` prints literally instead of expanding (or vice versa).
- **Process substitution avoids the pipe-into-`while`-subshell bug** — this is the single most-tested reason to know `<(...)` exists: `cmd | while read ...` runs the loop in a subshell and silently discards variable changes after the loop; `while read ... done < <(cmd)` does not.
- **`<(...)` and `>(...)` are bash/ksh/zsh extensions, NOT POSIX `sh`** — a script using process substitution needs a `#!/bin/bash` (or similar) shebang, not `#!/bin/sh`; will fail with a syntax error under `dash`.
- Mechanically, process substitution is implemented via a **named pipe or `/dev/fd/N`** — worth being able to say this out loud, and worth knowing that this is why some tools that `stat()` their input strictly can behave oddly with it (rare, but a known edge case).
- `<<-` strips **leading tabs only**, not spaces — a frequent gotcha when someone's editor auto-converts tabs to spaces and their "indented heredoc" silently stops working (the closing delimiter is no longer recognized, or stays indented in output).
- Here-strings (`<<<`) are the concise, single-line alternative to a one-line heredoc or an `echo | command` pipe — small but a sign of idiomatic bash when used correctly.
- `diff <(cmd1) <(cmd2)` — comparing two live command outputs without writing temp files — is a real, frequently-used ops pattern (config diffs, package-list diffs across hosts) and a common "show me you know a bash trick" interview ask.
- `tee >(cmd)` fans one stream out to multiple consumers concurrently — know this pattern for "process a live log stream into multiple filtered outputs at once" scenarios.
