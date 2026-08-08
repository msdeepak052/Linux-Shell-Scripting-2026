# Special Variables (`$0`, `$1..$9`, `$@`, `$*`, `$#`, `$?`, `$$`, `$!`)

Bash's built-in variables for talking to and about the script itself — arguments, PID, exit status.

## Explanation

| Variable | Meaning |
|---|---|
| `$0` | Name of the script itself (path as invoked) |
| `$1`, `$2`, ... `$9`, `${10}` | Positional parameters (script/function arguments); beyond 9 needs braces |
| `$@` | All positional parameters, **each as a separate word** (correct for looping) |
| `$*` | All positional parameters as **one single word**, joined by first char of `$IFS` |
| `$#` | Number of positional parameters |
| `$?` | Exit status of the **last executed command** (0 = success, non-zero = failure) |
| `$$` | PID of the current shell/script |
| `$!` | PID of the last background job launched with `&` |
| `$-` | Current shell option flags (e.g., `himBH`) |
| `$_` | Last argument of the previous command (handy interactively) |

The `"$@"` vs `"$*"` distinction is the classic interview trap: `"$@"` expands to `"$1" "$2" "$3"` (separate quoted words — safe when args have spaces), while `"$*"` expands to `"$1 $2 $3"` (one merged string). Unquoted, `$@` and `$*` behave identically (both word-split) — the difference only matters **when quoted**.

## Hands-On Examples

**1. Basic positional parameters**
```bash
$ cat > args.sh << 'EOF'
#!/bin/bash
echo "Script name: $0"
echo "First arg:   $1"
echo "Second arg:  $2"
echo "Arg count:   $#"
EOF
$ chmod +x args.sh
$ ./args.sh deploy prod
Script name: ./args.sh
First arg:   deploy
Second arg:  prod
Arg count:   2
```

**2. `$@` vs `$*` with quoted vs unquoted args (the classic trap)**
```bash
$ cat > loop_args.sh << 'EOF'
#!/bin/bash
echo "--- Using \"\$@\" ---"
for a in "$@"; do echo "[$a]"; done
echo "--- Using \"\$*\" ---"
for a in "$*"; do echo "[$a]"; done
EOF
$ chmod +x loop_args.sh
$ ./loop_args.sh "hello world" foo bar
--- Using "$@" ---
[hello world]
[foo]
[bar]
--- Using "$*" ---
[hello world foo bar]
```
Note: `"$@"` correctly kept `"hello world"` as ONE item; `"$*"` merged everything into a single string — critical when forwarding arguments (e.g., wrapper scripts around `kubectl`/`aws` CLI).

**3. `$?` — checking exit status**
```bash
$ grep "root" /etc/passwd
root:x:0:0:root:/root:/bin/bash
$ echo $?
0

$ grep "nonexistent_user_xyz" /etc/passwd
$ echo $?
1

$ ls /no/such/path
ls: cannot access '/no/such/path': No such file or directory
$ echo $?
2
```
Different non-zero codes can mean different things (grep: 1 = no match, 2 = error; `ls`: 2 = error) — always check tool-specific exit-code docs when scripting around them.

**4. `$$` and `$!` — PIDs for temp files and background job tracking**
```bash
$ echo "My PID is $$"
My PID is 48213

$ tmpfile="/tmp/report_$$.tmp"
$ echo "Using scratch file: $tmpfile"
Using scratch file: /tmp/report_48213.tmp

$ sleep 30 &
[1] 48250
$ echo "Background job PID: $!"
Background job PID: 48250
$ wait $!
$ echo "Background job finished with status $?"
Background job finished with status 0
```

**5. Real-world: a wrapper script forwarding all args safely to another command**
```bash
$ cat > kctl.sh << 'EOF'
#!/bin/bash
# Wraps kubectl with a default namespace, forwards all other args untouched
kubectl --namespace=platform-eng "$@"
EOF
$ chmod +x kctl.sh
$ ./kctl.sh get pods -l "app=payment service"
# "$@" correctly preserves "app=payment service" as ONE argument to -l
```

**6. `$#` for argument validation**
```bash
$ cat > deploy.sh << 'EOF'
#!/bin/bash
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <env> <version>" >&2
    exit 1
fi
echo "Deploying version $2 to $1"
EOF
$ chmod +x deploy.sh
$ ./deploy.sh
Usage: ./deploy.sh <env> <version>
$ echo $?
1
$ ./deploy.sh prod v2.3.1
Deploying version v2.3.1 to prod
```

## Practice Questions

1. What's printed by `$#` if a script `test.sh` is run as `./test.sh a b "c d"`? What about `$*` unquoted vs `"$*"` quoted in that same call?
2. Why does `"$@"` preserve argument boundaries correctly when forwarding arguments to another command, while `"$*"` does not? Give a concrete example where this breaks a wrapper script.
3. Write a script that checks `$?` after running `systemctl is-active nginx` and prints "UP" or "DOWN" accordingly.
4. What does `$$` give you, and why is it commonly used to build unique temp file names in scripts that might run concurrently?
5. You launch a long-running background job with `long_task.sh &`. How do you capture its PID and later `wait` specifically for that job (not any other background job) to check its exit status?
6. What's the difference in meaning of exit code `1` vs `2` vs `127` in bash (e.g., 127 specifically)?
7. Write a script skeleton that validates it received exactly 3 arguments, printing a usage message and exiting non-zero otherwise.
8. If a script is invoked as `bash /opt/scripts/../scripts/deploy.sh`, what exactly does `$0` contain? Does it get normalized?
9. What does `${10}` give you versus `$10`, and why does bash require the braces here?
10. In a script, `command1; command2` runs — how would you check the exit status of `command1` specifically if `command2` has already run and overwritten `$?`?

## Interview Key Points

- **`"$@"` vs `"$*"`** is one of the most commonly asked bash trivia questions — always answer with the quoted-vs-unquoted nuance, not just "they're the same."
- `$?` reflects the **immediately preceding** command only — must be captured right after the command you care about, before running anything else (including `echo` itself, which is why `rc=$?; echo "$rc"` is the safe pattern, not `echo $?` after other logic).
- `$$` is the current shell's PID — inside a subshell/background job it may differ from the parent's PID (know that `$BASHPID` differs from `$$` inside subshells in some cases, while `$$` inside a subshell still reports the *original* shell's PID in bash — a subtle but real gotcha).
- `$!` only tracks the PID of the **most recently backgrounded** job — for multiple parallel jobs, capture each PID immediately after backgrounding it.
- Exit code conventions: `0` = success, `1`-`125` = command-specific error, `126` = command found but not executable, `127` = command not found, `128+N` = terminated by signal N.
- `$0` is *not guaranteed* to be a clean script name — it reflects exactly how the script was invoked (relative path, absolute path, or even just the name if run via `$PATH`), useful to know for usage/help messages.
