# Robust Error Handling: `set -e`, `set -u`, `set -o pipefail`, `trap`

Strict mode catches failures; `trap` guarantees cleanup happens no matter *how* the script dies — combined, they're the backbone of production-grade bash.

## Explanation

**Strict mode recap** (see Stage 6 for `$?`/`&&`/`||` basics):
```bash
set -e            # exit on any unhandled non-zero exit status
set -u            # error on unset variables
set -o pipefail   # pipeline fails if ANY stage fails, not just the last
set -euo pipefail # combined header
```

**`trap`** registers a handler that runs when the shell receives a signal or hits certain events:
```bash
trap 'commands' SIGNAL_OR_EVENT
```
Common triggers:
- `EXIT` — fires on **any** script termination: normal exit, `exit N`, or an uncaught signal. This is the workhorse for cleanup (temp files, lockfiles, background processes) because it fires unconditionally.
- `ERR` — fires whenever a command fails (respects `set -e` semantics); useful for logging the failure point before exit. Only fires for command failures, not for signals.
- `INT` — fires on Ctrl+C (`SIGINT`).
- `TERM` — fires on `kill <pid>` (default signal, `SIGTERM`) — how orchestrators (systemd, Kubernetes, `docker stop`) ask a process to shut down gracefully.
- `HUP` — terminal hangup / "reload config" convention for daemons.

**Key mechanics/gotchas**:
- Multiple traps can be set for different signals; a later `trap ... EXIT` overwrites an earlier one for the same event — it does not stack. To combine cleanup logic, call one function from the trap.
- `trap - SIGNAL` removes/resets a trap to default behavior.
- `trap ''  SIGNAL` (empty command) **ignores** the signal entirely.
- An `EXIT` trap fires even when `INT`/`TERM` traps also fire — order is: signal-specific trap runs, then (unless it calls `exit` itself) the script continues or terminates and the `EXIT` trap runs last. Explicitly `exit`ing from an `INT`/`TERM` handler is the safest pattern so the exit code reflects the signal.
- `$?` inside an `EXIT` trap reflects the exit code that triggered it — capture it early (`trap 'rc=$?; cleanup; exit $rc' EXIT`) if you need to preserve/report it.
- Traps are **not inherited by subshells** started with `()` but ARE inherited by functions and `$( )` command substitutions run in the current shell process... actually command substitutions run in subshells too, so traps don't propagate there either — only inherited into shell functions.
- `set -e` does NOT fire inside `if`/`while` conditions, before `&&`/`||`, or on the last command of a pipeline unless `pipefail` is also set — the classic set of exceptions.
- Combine `trap` with strict mode: strict mode causes the failure, `trap ... EXIT` guarantees you still clean up even though the script died abruptly.

## Hands-On Examples

**1. Basic EXIT trap for temp file cleanup**
```bash
$ cat > backup.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Working in $TMPDIR"
tar -czf "$TMPDIR/data.tar.gz" /app/data
cp "$TMPDIR/data.tar.gz" /backups/
echo "Backup complete"
EOF
$ ./backup.sh
Working in /tmp/tmp.Xk3nP9qLrZ
Backup complete
$ ls /tmp/tmp.Xk3nP9qLrZ 2>&1
ls: cannot access '/tmp/tmp.Xk3nP9qLrZ': No such file or directory   # cleaned up automatically
```

**2. Lockfile cleanup on any exit path (normal, error, or Ctrl+C)**
```bash
$ cat > deploy.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOCKFILE=/var/run/deploy.lock

if [[ -e "$LOCKFILE" ]]; then
    echo "ERROR: deploy already running (pid $(cat "$LOCKFILE"))" >&2
    exit 1
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

echo "Deploying..."
sleep 5
echo "Deploy finished"
EOF
$ ./deploy.sh &
[1] 8842
$ kill -TERM 8842
$ ls /var/run/deploy.lock 2>&1
ls: cannot access '/var/run/deploy.lock': No such file or directory   # trap still ran on SIGTERM
```

**3. Preserving the real exit code through an EXIT trap**
```bash
$ cat > safe_exit.sh << 'EOF'
#!/usr/bin/env bash
cleanup() {
    local rc=$?
    echo "Cleaning up (exit code was $rc)..."
    rm -f /tmp/work.$$
    exit "$rc"
}
trap cleanup EXIT
touch /tmp/work.$$
false   # simulate failure
EOF
$ ./safe_exit.sh; echo "Caller saw: $?"
Cleaning up (exit code was 1)...
Caller saw: 1
```

**4. `ERR` trap for logging exactly where a script failed**
```bash
$ cat > migrate.sh << 'EOF'
#!/usr/bin/env bash
set -eE -o pipefail   # -E lets ERR trap propagate into functions
trap 'echo "FAILED at line $LINENO running: $BASH_COMMAND" >&2' ERR

run_migration() {
    psql -c "ALTER TABLE users ADD COLUMN bogus_syntax(("
}
run_migration
EOF
$ ./migrate.sh
FAILED at line 6 running: psql -c "ALTER TABLE users ADD COLUMN bogus_syntax(("
```

**5. `INT`/`TERM` handlers for graceful shutdown of a long-running worker**
```bash
$ cat > worker.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
running=true
graceful_shutdown() {
    echo "Received shutdown signal, finishing current job..."
    running=false
}
trap graceful_shutdown INT TERM

while $running; do
    echo "Processing queue item..."
    sleep 2
done
echo "Worker exited cleanly"
EOF
$ ./worker.sh &
[1] 9210
Processing queue item...
Processing queue item...
$ kill -TERM 9210
Received shutdown signal, finishing current job...
Worker exited cleanly
```

**6. Multiple cleanup actions combined via one function**
```bash
$ cat > provision.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
TMPDIR=$(mktemp -d)
PIDFILE=/var/run/provision.pid
echo $$ > "$PIDFILE"

cleanup() {
    echo "Running cleanup..."
    rm -rf "$TMPDIR"
    rm -f "$PIDFILE"
    kill "${BG_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

nc -l 8888 & BG_PID=$!
echo "Provisioning in $TMPDIR, listener pid $BG_PID"
sleep 1
exit 0
EOF
$ ./provision.sh
Provisioning in /tmp/tmp.aB3xQ, listener pid 9301
Running cleanup...
```

**7. Ignoring a signal on purpose (protecting a critical section)**
```bash
$ cat > critical_write.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "Entering critical section, SIGINT ignored"
trap '' INT
cp /data/critical.db /data/critical.db.bak
sync
trap - INT   # restore default handling afterward
echo "Critical section done, SIGINT restored"
EOF
$ ./critical_write.sh &
$ kill -INT $!    # ignored while trap '' INT is active
Entering critical section, SIGINT ignored
Critical section done, SIGINT restored
```

**8. `set -e` exceptions still apply even with traps in place**
```bash
$ cat > exceptions.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo "exiting with $?"' EXIT

if grep -q "nonexistent" /etc/hostname; then   # failure here does NOT trigger set -e
    echo "found"
fi
echo "still running after failed grep in if-condition"
EOF
$ ./exceptions.sh
still running after failed grep in if-condition
exiting with 0
```

## Practice Questions

1. Why is `trap cleanup EXIT` almost always safer than putting cleanup code at the bottom of a script? What failure mode does it protect against that bottom-of-script cleanup misses?
2. Explain the difference between the `EXIT` trap and the `ERR` trap — when does each fire, and can both fire for the same failure?
3. Write a script that creates a lockfile at `/var/run/myjob.lock`, refuses to run if the lock already exists, and guarantees the lock is removed on normal exit, error, and `SIGTERM`.
4. What does `set -eE` do differently from plain `set -e` with respect to traps, and why does it matter for an `ERR` trap set inside a function?
5. Given `trap 'rm -f "$TMPFILE"' EXIT` followed later by `trap 'echo bye' EXIT`, what happens to the temp-file cleanup? How would you register both without losing either?
6. How do you preserve and propagate the original non-zero exit code from inside an `EXIT` trap, instead of the trap accidentally causing the script to exit 0?
7. Why don't traps set in the main script automatically apply inside a subshell like `(cd /tmp && risky_command)` or a `$(...)` command substitution?
8. Describe how you'd implement graceful shutdown for a worker script that needs to finish its current unit of work before exiting when it receives `SIGTERM` from Kubernetes during a pod termination.
9. What's the effect of `trap '' INT`, and give a legitimate production reason to temporarily ignore `SIGINT` in part of a script.
10. A script hits `set -e` inside an `if some_command; then` block and does NOT exit even though `some_command` failed. Is this a bug in `set -e`, and how would you explain it in an interview?

## Interview Key Points

- `trap ... EXIT` is the standard, reliable place for cleanup — it fires on normal completion, `exit N`, AND uncaught signals, unlike code placed at the end of a script (which never runs if the script dies early).
- Know the four traps cold: **EXIT** (always, on termination), **ERR** (on command failure, respects `set -e`), **INT** (Ctrl+C / SIGINT), **TERM** (`kill`, SIGTERM — how orchestrators ask for graceful shutdown).
- `set -eE -o pipefail` (`-E`) is required for an `ERR` trap to propagate correctly into functions and subshells — a commonly missed detail.
- `$?` inside an `EXIT` trap holds the triggering exit code — capture it into a local variable immediately (`rc=$?`) before running other commands that would overwrite it, then `exit "$rc"` at the end of the trap.
- Traps don't stack — setting a new `trap ... EXIT` silently replaces the previous one. Route all cleanup through a single `cleanup()` function to avoid this trap (pun intended).
- `trap '' SIGNAL` ignores a signal; `trap - SIGNAL` restores default behavior — know the syntactic difference, it's a common gotcha.
- Real production use case interviewers love: lockfiles and PID files that MUST be removed even if the script is killed — this is the textbook justification for `trap ... EXIT INT TERM`.
- Traps are not inherited into subshells/command substitutions, only into functions of the same shell — relevant when reasoning about where cleanup logic actually executes.
