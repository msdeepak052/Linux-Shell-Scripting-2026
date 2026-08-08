# Debugging: `bash -x`, `set -x`/`set +x`, ShellCheck

When a script misbehaves in production, tracing exactly what ran (`-x`) and catching bugs before they ship (ShellCheck) are the two core debugging skills expected of a senior engineer.

## Explanation

**`bash -x script.sh`** (or `sh -x`) runs the whole script in trace mode — every command is printed to stderr, prefixed with `+`, after variable/glob expansion but before execution, so you see the *actual* command that ran, not the literal source line.

**`set -x`** enables the same tracing from *inside* a script/shell, and **`set +x`** turns it off — useful for bracketing just the suspicious section instead of drowning in trace output for the whole script:
```bash
set -x
suspicious_function arg1 arg2
set +x
```

**`PS4`** controls the trace-line prefix (default `+ `). Overriding it to include function name, line number, and script name is a huge quality-of-life upgrade for scripts with functions:
```bash
export PS4='+ ${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]:-main}: '
```

**Other debugging flags** (can combine with `-x`):
- `set -v` (verbose) — prints each line of the script AS WRITTEN (source form) before executing, complementary to `-x` which prints the expanded form.
- `set -n` (noexec) — syntax-check only, parses the script without running any commands. Good CI smoke test: `bash -n script.sh`.
- `bash -x -v script.sh` — combine for maximum visibility (source line, then expanded command).
- Redirecting trace output separately from program output: `bash -x script.sh 2> trace.log` keeps `+`-prefixed trace lines out of stdout.

**Interactive/targeted debugging**:
- Sprinkle `set -x` / `set +x` around a specific block rather than tracing an entire long script.
- `trap 'echo "line $LINENO: $BASH_COMMAND"' DEBUG` — a `DEBUG` trap fires before every command, giving line-by-line visibility with custom formatting (heavier than `-x` but fully customizable).
- `bashdb` exists as a true interactive step-debugger (breakpoints, `step`/`next`/`print`) for very complex scripts, though `-x` covers the vast majority of real needs.

**ShellCheck** is the standard static analyzer for shell scripts — catches quoting bugs, unreachable code, incorrect test operators, and dozens of other classes of real-world bugs *before* runtime:
```bash
shellcheck script.sh
```
- Reports issues as `SC####` codes (e.g., `SC2086` = unquoted variable that should be quoted to prevent word-splitting/globbing) with a severity (`error`/`warning`/`info`/`style`) and a plain-English explanation.
- Integrates into CI (`shellcheck **/*.sh`, exits non-zero on any error/warning by default) and editors (VS Code, vim plugins) for inline linting.
- `# shellcheck disable=SC2086` above a line suppresses a specific warning when you've deliberately decided it's not applicable — always comment *why* when doing this.
- `shellcheck -x script.sh` follows `source`d files so included libraries get checked too.
- `shellcheck -f json script.sh` emits machine-readable JSON output for CI tooling to parse.

## Hands-On Examples

**1. `bash -x` — trace showing expanded values, not source**
```bash
$ cat > greet.sh << 'EOF'
#!/usr/bin/env bash
NAME="World"
echo "Hello, $NAME!"
EOF
$ bash -x greet.sh
+ NAME=World
+ echo 'Hello, World!'
Hello, World!
```

**2. Bracketing a suspicious block with `set -x` / `set +x`**
```bash
$ cat > deploy.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "Starting deploy"

set -x
IMAGE_TAG=$(git rev-parse --short HEAD)
docker build -t "myapp:$IMAGE_TAG" .
set +x

echo "Deploy done"
EOF
$ ./deploy.sh
Starting deploy
+ git rev-parse --short HEAD
+ IMAGE_TAG=a3f9c21
+ docker build -t myapp:a3f9c21 .
...
+ set +x
Deploy done
```

**3. Custom `PS4` for line-number and function context in trace output**
```bash
$ cat > worker.sh << 'EOF'
#!/usr/bin/env bash
export PS4='+ ${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]:-main}(): '
process_item() {
    local item="$1"
    echo "Processing $item"
}
set -x
process_item "job-42"
EOF
$ bash worker.sh
+ worker.sh:7:main(): process_item job-42
+ worker.sh:4:process_item(): local item=job-42
+ worker.sh:5:process_item(): echo 'Processing job-42'
Processing job-42
```

**4. `bash -n` — syntax-only check, no execution (safe pre-flight in CI)**
```bash
$ cat > broken.sh << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "prod" ]
    echo "deploying to prod"
fi
EOF
$ bash -n broken.sh
broken.sh: line 3: syntax error near unexpected token `echo'
broken.sh: line 3: `    echo "deploying to prod"'
$ echo $?
2
```

**5. ShellCheck catching a classic unquoted-variable bug**
```bash
$ cat > cleanup.sh << 'EOF'
#!/usr/bin/env bash
LOG_DIR=$1
rm -rf $LOG_DIR/*.log
EOF
$ shellcheck cleanup.sh

In cleanup.sh line 2:
LOG_DIR=$1
^-- SC2034 (warning): LOG_DIR appears unused. Verify use (or export if used externally).

In cleanup.sh line 3:
rm -rf $LOG_DIR/*.log
        ^-- SC2086 (info): Double quote to prevent globbing and word splitting.

For more information:
  https://www.shellcheck.net/wiki/SC2086 -- Double quote to prevent globbing ...
```
This is exactly the class of bug that causes `rm -rf /*.log` disasters when `$LOG_DIR` is empty and unquoted.

**6. Fixing ShellCheck findings and re-verifying clean**
```bash
$ cat > cleanup_fixed.sh << 'EOF'
#!/usr/bin/env bash
LOG_DIR="${1:?ERROR: log dir required}"
rm -rf "${LOG_DIR:?}"/*.log
EOF
$ shellcheck cleanup_fixed.sh
$ echo $?
0
```

**7. Suppressing a deliberate ShellCheck warning with justification**
```bash
$ cat > version_check.sh << 'EOF'
#!/usr/bin/env bash
VERSION_CMD="kubectl version --client"
# shellcheck disable=SC2086
# Intentionally unquoted: VERSION_CMD is a controlled, space-separated command, not user input
eval $VERSION_CMD
EOF
$ shellcheck version_check.sh
$ echo $?
0
```

**8. `DEBUG` trap for custom line-by-line tracing (heavier alternative to `-x`)**
```bash
$ cat > trace_debug.sh << 'EOF'
#!/usr/bin/env bash
trap 'echo "[TRACE] line $LINENO: $BASH_COMMAND" >&2' DEBUG
count=0
count=$((count + 1))
echo "count=$count"
EOF
$ ./trace_debug.sh
[TRACE] line 3: count=0
[TRACE] line 4: count=$((count + 1))
[TRACE] line 5: echo "count=$count"
count=1
```

## Practice Questions

1. What's the practical difference between what `set -x` prints and what `set -v` prints, for the same line of code?
2. You want to trace only one suspicious function in a 300-line script without drowning in output. How do you scope tracing to just that section?
3. Write and explain a custom `PS4` that shows the source filename, line number, and current function name in trace output.
4. What does `bash -n script.sh` do, and how would you wire it into a CI pipeline as a cheap pre-flight check before running ShellCheck?
5. Explain what `SC2086` means, show an example line that triggers it, and show the fixed version.
6. When (if ever) is it appropriate to add `# shellcheck disable=SC2086` above a line, and what should always accompany that comment?
7. How would you separate `-x` trace output from a script's normal stdout so the trace doesn't pollute output being piped/parsed downstream?
8. What is a `DEBUG` trap, how does it differ from `set -x`, and when would you prefer it?
9. A script works when run manually but fails silently in cron. What debugging technique(s) would you apply to figure out what's different about the cron execution environment?
10. Describe how you'd integrate ShellCheck into a CI pipeline so that a warning-level finding (not just error-level) fails the build, and how you'd handle a legacy script with 40 pre-existing warnings you don't have time to fix today.

## Interview Key Points

- `bash -x` traces the **expanded** command (after variable substitution/globbing); `set -v` echoes the **literal source line** before execution — know both and when each is more useful.
- Custom `PS4` (especially with `${LINENO}` and `${FUNCNAME[0]}`) is a senior-level detail that shows you've actually debugged non-trivial scripts, not just toy ones.
- `bash -n` (syntax check, no execution) is the cheap first line of defense in CI, run before ShellCheck and before actually executing anything.
- ShellCheck is close to a mandatory tool mention for "how do you ensure script quality" — know the `SC####` convention and be able to explain at least `SC2086` (unquoted variables) from memory, since it's the most common and most dangerous class of bug it catches.
- Suppressing a ShellCheck warning (`# shellcheck disable=SCXXXX`) should always be a deliberate, commented decision — blanket-disabling checks is a red flag in review.
- `set -x` output goes to **stderr**, not stdout — important when a script's stdout is piped somewhere and you don't want trace noise mixed in.
- Mention the `DEBUG` trap as the heavier, fully-customizable alternative to `-x` for cases needing custom per-command instrumentation (e.g., timing each command, structured trace logs).
- Real interview scenario to be ready for: "cron job works manually but fails when scheduled" — tie it back to debugging technique (`-x`, explicit `PATH`/env logging, redirecting output to a log file) rather than guessing blindly.
