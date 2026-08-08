# Locking to Prevent Concurrent Execution: `flock`

Two overlapping cron runs of the same script (a slow run plus its own next scheduled trigger) is one of the most common causes of race conditions and corrupted state in production — `flock` solves it with kernel-level advisory locking.

## Explanation

**The problem**: a naive "check for a PID file, refuse to run if it exists" approach (manual lockfiles) has race conditions of its own (two processes can both pass the check before either writes the file) and leaves stale locks behind if a process is killed with `SIGKILL` (which bypasses traps). `flock` avoids both problems by using the kernel's `flock(2)` advisory file-locking syscall — the lock is automatically released when the holding process exits or dies, no matter how, including `SIGKILL` or a crash.

**Basic forms**:
```bash
flock /var/lock/myjob.lock -c "command to run"       # wraps a command string
flock /var/lock/myjob.lock command arg1 arg2          # wraps a command + args directly

# Or, the more common in-script pattern using a held file descriptor:
exec 200>/var/lock/myjob.lock   # open FD 200 on the lock file (creates it if missing)
flock -n 200 || { echo "already running"; exit 1; }
# ... critical section ...
# lock auto-releases when the script exits and FD 200 closes
```

**Key flags**:
- `-n` / `--nonblock` — fail immediately (non-zero exit) if the lock is already held, instead of the default behavior of blocking until it's free.
- `-w SECONDS` / `--wait SECONDS` — block up to N seconds, then give up.
- `-x` — exclusive lock (the default; only one holder at a time). `-s` — shared lock (multiple readers can hold it simultaneously, useful for read-heavy coordination).
- `-c "cmd"` — run a command string via the shell; alternative simpler form: `flock lockfile command args...` runs the command directly without a subshell.
- `-o` / `--close` — close the file descriptor before running the command (rarely needed).

**Two usage patterns**:
1. **Wrapper form** (`flock file -c "..."`) — simplest, good for one-off cron entries where you don't want to edit the script itself:
   ```
   */5 * * * * flock -n /var/lock/sync.lock /opt/scripts/sync.sh
   ```
2. **In-script FD form** (`exec 200>file; flock -n 200`) — better when the script needs to do other things before/after the locked section, or needs to log a "skipped, already running" message with full control.

**Gotchas**:
- The lock is tied to the **open file descriptor**, not the file path — if you re-open the file (new FD) you get a new, independent lock; this is why the `exec 200>file` pattern (keeping one FD open for the script's whole lifetime) is important for in-script use.
- Locks are per-inode: deleting and recreating the lock file can confuse concurrent processes into thinking they hold different locks. Best practice: never `rm` the lock file from inside the script; let it persist (it's just an empty marker) and rely on `flock` semantics, not file existence.
- Advisory, not mandatory: `flock` only prevents contention between processes that themselves use `flock` on that file — it does NOT prevent a process from writing to the underlying data file directly if it ignores the lock discipline. Everyone touching the shared resource must cooperate via the same lock.
- Unlike a manual "check PID file" approach, `flock`'s kernel-held lock is automatically released on process death (including `SIGKILL`, unlike traps which SIGKILL bypasses) — this is `flock`'s single biggest advantage over hand-rolled PID-file locking.
- NFS caveat: `flock` on some older NFS configurations may not work correctly across hosts — locking across a distributed filesystem needs verification in that environment.

## Hands-On Examples

**1. Simplest form — wrapping a cron job to prevent overlap**
```bash
$ crontab -l
*/5 * * * * flock -n /var/lock/sync_inventory.lock /opt/scripts/sync_inventory.sh
# If a run takes longer than 5 minutes, the next trigger's flock -n fails fast
# instead of starting a second overlapping sync.
```

**2. In-script FD-based locking with a clean "already running" message**
```bash
$ cat > sync_inventory.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOCK_FILE=/var/lock/sync_inventory.lock
exec 200>"$LOCK_FILE"

if ! flock -n 200; then
    echo "Another sync_inventory.sh is already running, exiting" >&2
    exit 1
fi

echo "Lock acquired, running sync..."
sleep 30
echo "Sync complete"
EOF
$ ./sync_inventory.sh &
[1] 15021
$ ./sync_inventory.sh
Another sync_inventory.sh is already running, exiting
$ wait
Lock acquired, running sync...
Sync complete
```

**3. Blocking with a timeout instead of failing immediately**
```bash
$ cat > db_maintenance.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec 200>/var/lock/db_maintenance.lock

if ! flock -w 60 200; then
    echo "Could not acquire lock within 60s, another maintenance run is stuck" >&2
    exit 1
fi
echo "Running VACUUM..."
psql -c "VACUUM ANALYZE;"
EOF
$ ./db_maintenance.sh
Running VACUUM...
```

**4. Proving `flock` survives `SIGKILL` (unlike a manual PID-file lock, which would leak)**
```bash
$ cat > worker.sh << 'EOF'
#!/usr/bin/env bash
exec 200>/var/lock/worker.lock
flock -n 200 || { echo "busy"; exit 1; }
echo "Working (pid $$)..."
sleep 300
EOF
$ ./worker.sh &
[1] 15200
Working (pid 15200)...
$ kill -9 15200          # simulate a hard crash, bypasses any trap-based cleanup
$ flock -n /var/lock/worker.lock -c 'echo "lock is free"'
lock is free              # kernel released the lock automatically on process death
```

**5. Shared (read) vs exclusive (write) locks for a config file readers/writer pattern**
```bash
$ cat > read_config.sh << 'EOF'
#!/usr/bin/env bash
exec 200</etc/myapp/config.yml
flock -s 200        # shared lock: multiple readers can hold this simultaneously
cat /etc/myapp/config.yml
EOF
$ cat > write_config.sh << 'EOF'
#!/usr/bin/env bash
exec 200>/etc/myapp/config.yml
flock -x -w 10 200 || { echo "Could not get exclusive lock, readers active"; exit 1; }
echo "new_setting: true" >> /etc/myapp/config.yml
EOF
$ ./read_config.sh & ./read_config.sh &   # both proceed concurrently (shared lock)
wait
```

**6. Guarding a critical section mid-script rather than the whole script**
```bash
$ cat > rotate_and_upload.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "Preparing files (no lock needed here)..."
tar -czf /tmp/batch.tar.gz /data/pending/*

(
    flock -x -w 30 201 || { echo "Upload slot busy, aborting"; exit 1; }
    echo "Uploading (locked section)..."
    aws s3 cp /tmp/batch.tar.gz s3://bucket/batch.tar.gz
) 201>/var/lock/s3_upload.lock

echo "Done (lock released automatically after subshell exits)"
EOF
```

**7. Wrapper-style `flock -c` for an ad-hoc one-liner without editing the target script**
```bash
$ flock -n /var/lock/report.lock -c "python3 /opt/scripts/generate_report.py --daily"
$ echo $?
0
$ flock -n /var/lock/report.lock -c "echo test" &
$ flock -n /var/lock/report.lock -c "echo test2"
flock: failed to get lock
$ echo $?
1
```

**8. Combining `flock` with structured logging and `trap` cleanup for a full production pattern**
```bash
$ cat > nightly_job.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOCK_FILE=/var/lock/nightly_job.lock
log() { printf '%s [%s] %s\n' "$(date -Iseconds)" "$1" "${*:2}" >&2; }

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log WARN "nightly_job.sh already running, skipping this trigger"
    exit 0    # exit 0: this is an expected outcome for cron, not a failure
fi

trap 'log INFO "nightly_job finished (exit $?)"' EXIT
log INFO "Lock acquired, starting nightly job"
/opt/scripts/heavy_batch_process.sh
log INFO "Batch process complete"
EOF
$ ./nightly_job.sh
2026-08-08T02:00:00+00:00 [INFO] Lock acquired, starting nightly job
2026-08-08T02:14:22+00:00 [INFO] Batch process complete
2026-08-08T02:14:22+00:00 [INFO] nightly_job finished (exit 0)
```

## Practice Questions

1. Why is `flock` generally safer than a hand-rolled "check if PID file exists, else create it" locking scheme? What specific race condition and what specific crash scenario does `flock` handle correctly that the manual approach doesn't?
2. Write an in-script locking pattern using `exec 200>lockfile` and `flock -n 200` that prints "already running" and exits cleanly if another instance holds the lock.
3. What's the difference between `flock -n` and `flock -w 30`, and when would you choose blocking-with-timeout over fail-immediately?
4. Explain why the lock is tied to the open file descriptor rather than the file's path or contents, and why that matters for how you write the `exec` line.
5. A teammate's script does `rm -f "$LOCK_FILE"` at the end to "clean up" the lock file. Why is this unnecessary at best and a subtle bug at worst?
6. Write a crontab entry that ensures a 10-minute sync script never runs twice in an overlapping window, using `flock` in wrapper form.
7. What's the difference between a shared (`-s`) and exclusive (`-x`, default) lock, and give a realistic scenario where you'd deliberately use a shared lock.
8. How would you scope a lock to just one critical section in the middle of a longer script, rather than locking for the script's entire runtime? What does wrapping that section in a subshell with its own FD redirect accomplish?
9. Demonstrate (in words) what happens to a `flock`-held lock if the holding process receives `SIGKILL` — contrast this with what would happen to a `trap`-based cleanup under the same signal.
10. Design a nightly batch script that: acquires an exclusive lock, exits 0 (not an error) if another instance is already running, logs structured start/finish messages, and processes a batch job — combining locking, logging, and clean exit-code semantics.

## Interview Key Points

- **`flock`'s core advantage over a manual PID-file lock**: the kernel automatically releases the lock when the holding process's file descriptor closes — including on `SIGKILL` or a hard crash — whereas PID-file/trap-based cleanup can leave a stale lock behind if the process is killed ungracefully. This is the single most important point to articulate.
- Know the `exec 200>lockfile` + `flock -n 200` idiom well enough to write it from memory — it's the standard in-script pattern, distinct from the simpler cron-wrapper form `flock -n lockfile -c "..."`.
- `-n` (fail fast) vs `-w SECONDS` (bounded wait) vs default (block forever) — be explicit about which one is appropriate for a cron job (`-n`, to skip the overlapping run) versus a job that should queue behind another (`-w` or blocking).
- The lock is per-file-descriptor/per-inode, not per-path — explain why deleting/recreating the lock file is risky and why you should never `rm` a `flock`-managed lock file from inside the script.
- `flock` is advisory, not mandatory — it only coordinates processes that themselves call `flock` on the same file; a process that ignores the convention and writes directly is not blocked. This nuance (advisory vs mandatory locking) is a good differentiator for a senior answer.
- Classic real-world justification interviewers want to hear: preventing overlapping cron runs of a slow job (e.g., a sync or backup script whose runtime occasionally exceeds its schedule interval) — this is the textbook `flock` use case.
- Exiting `0` (not a failure code) when a script deliberately skips because the lock is held is a subtle but important design choice for cron/monitoring integration — an "already running, skipping" outcome shouldn't page anyone or count as a failure.
- Combine with the `trap ... EXIT` pattern (Stage-7 file 04) and structured logging (file 09) for the complete production pattern interviewers expect at senior level: lock, log, guaranteed cleanup, correct exit-code semantics.
