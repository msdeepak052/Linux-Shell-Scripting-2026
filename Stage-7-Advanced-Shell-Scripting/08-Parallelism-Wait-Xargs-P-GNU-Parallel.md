# Parallelism: `wait`, `xargs -P`, GNU `parallel`

Running independent tasks (downloads, per-host checks, file conversions) sequentially wastes wall-clock time — bash offers three escalating tools to parallelize them safely.

## Explanation

**Background jobs + `wait`** — the most basic mechanism: `&` backgrounds a command, `wait` blocks until background job(s) finish.
```bash
cmd1 & cmd2 & cmd3 &
wait              # wait for ALL background jobs
wait $pid1        # wait for one specific job (by PID, from $!)
wait -n           # wait for the NEXT job to finish (bash 4.3+), useful for a worker pool
```
- `$!` holds the PID of the most recently backgrounded process — capture it immediately if you need to `wait` on or `kill` that specific job later.
- `wait` without arguments returns 0 only if ALL waited-on jobs succeeded... actually `wait` (no args) itself always returns 0; to check individual job status, `wait` each PID separately and check its own exit code.
- Rolling your own concurrency limiter with plain `&`/`wait` requires manually counting active jobs — doable but clunky for anything beyond a handful of parallel tasks (see Example 3).

**`xargs -P`** — turns a list of inputs into N parallel invocations of a command:
```bash
cat urls.txt | xargs -P 8 -I{} curl -sO {}
```
- `-P N` sets max concurrent processes (`-P 0` = unlimited, bounded only by system resources — use with caution).
- `-I{}` defines a placeholder substituted with each input line; needed when the input must be inserted mid-command rather than appended at the end.
- `-n 1` forces one argument per invocation (often paired with `-P` so each parallel worker handles exactly one item).
- `-0` / paired with `find -print0` handles filenames with spaces/newlines safely — always prefer this over plain newline-split input when filenames are involved.
- Simpler than GNU `parallel` for straightforward "run this command N-at-a-time over a list" cases; ships with coreutils/findutils so it's virtually always available, unlike `parallel`.

**GNU `parallel`** — a more powerful, purpose-built tool (separate package, `apt install parallel`):
```bash
cat hosts.txt | parallel -j 10 'ssh {} uptime'
```
- `-j N` = max jobs (also accepts `-j 200%` = 2x CPU cores, `-j 0` = as many as CPU cores).
- `{}` = whole input line, `{.}` = input without extension, `{1}`/`{2}` = fields when multiple input sources are combined.
- Preserves output ordering with `--keep-order` (by default output can interleave across parallel jobs, unlike a naive loop).
- Built-in progress bar (`--progress`), retry on failure (`--retries N`), dry-run (`--dry-run`), and joblog (`--joblog log.txt`) for auditing exactly what ran and its exit code — features `xargs -P` lacks.
- Can distribute jobs across remote hosts via SSH (`-S host1,host2`), which `xargs` cannot do at all.

**When to choose which**:
- Simple "N things run independently, I'll wait for them" in a script you're writing from scratch → `&` + `wait`.
- "Run this command over a list of inputs, N at a time" and you can't install extra packages → `xargs -P`.
- Need retries, joblogs, remote execution, or complex per-item logic → GNU `parallel`.

**Gotchas**:
- Background jobs share the parent shell's file descriptors — redirect each job's output to a separate file/log to avoid interleaved/corrupted output.
- Unbounded backgrounding (`for f in *; do process "$f" & done`) can fork-bomb a box with thousands of files — always cap concurrency.
- Exit codes of background jobs are only available via `wait`; a bare `job &` swallows its exit status unless you capture and check it explicitly.

## Hands-On Examples

**1. Basic `&` + `wait` for a fixed set of independent tasks**
```bash
$ cat > backup_all.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
tar -czf /backups/app.tar.gz /app &
tar -czf /backups/db.tar.gz /var/lib/postgresql &
tar -czf /backups/logs.tar.gz /var/log &
wait
echo "All backups complete"
EOF
$ time ./backup_all.sh
All backups complete
real    0m12.4s   # vs ~35s if run sequentially
```

**2. Capturing PIDs and checking individual exit statuses**
```bash
$ cat > healthchecks.sh << 'EOF'
#!/usr/bin/env bash
declare -A pids
for host in web1 web2 web3; do
    ssh "$host" "systemctl is-active myapp" &
    pids[$host]=$!
done

fail=0
for host in "${!pids[@]}"; do
    if wait "${pids[$host]}"; then
        echo "$host: OK"
    else
        echo "$host: FAILED"
        fail=1
    fi
done
exit $fail
EOF
$ ./healthchecks.sh
web1: OK
web3: OK
web2: FAILED
```

**3. Hand-rolled concurrency limiter with `wait -n`**
```bash
$ cat > process_queue.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
MAX_JOBS=4
files=(/data/*.csv)

for f in "${files[@]}"; do
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do
        wait -n     # free up a slot as soon as ANY job finishes
    done
    process_csv "$f" &
done
wait
echo "Processed ${#files[@]} files, max $MAX_JOBS concurrent"
EOF
```

**4. `xargs -P` for parallel downloads**
```bash
$ cat urls.txt
https://cdn.internal/pkg1.tar.gz
https://cdn.internal/pkg2.tar.gz
https://cdn.internal/pkg3.tar.gz
https://cdn.internal/pkg4.tar.gz
$ xargs -P 4 -n 1 curl -sO < urls.txt
$ ls *.tar.gz
pkg1.tar.gz  pkg2.tar.gz  pkg3.tar.gz  pkg4.tar.gz
```

**5. `xargs -P` with `-I{}` for a mid-command placeholder, and null-delimited input for safe filenames**
```bash
$ find /data -name "*.log" -print0 | xargs -0 -P 8 -I{} gzip {}
$ find /data -name "*.gz" | wc -l
142
```

**6. GNU `parallel` running a command across a host list, with a joblog**
```bash
$ cat hosts.txt
web1.internal
web2.internal
web3.internal
$ parallel -j 10 --joblog /tmp/deploy.log 'ssh {} "sudo systemctl restart myapp"' < hosts.txt
$ column -t /tmp/deploy.log
Seq  Host  Starttime   JobRuntime  Send  Receive  Exitval  Signal  Command
1    :     1712345.1   2.341       0     0        0        0       ssh web1.internal "sudo systemctl restart myapp"
2    :     1712345.1   2.198       0     0        0        0       ssh web2.internal "sudo systemctl restart myapp"
3    :     1712345.1   2.501       0     0        0        0       ssh web3.internal "sudo systemctl restart myapp"
```

**7. GNU `parallel` with retries and preserved output order**
```bash
$ parallel -j 5 --retries 3 --keep-order 'curl -sf https://api.internal/health/{}' ::: svc1 svc2 svc3 svc4 svc5
{"service":"svc1","status":"ok"}
{"service":"svc2","status":"ok"}
{"service":"svc3","status":"ok"}
{"service":"svc4","status":"ok"}
{"service":"svc5","status":"ok"}
```

**8. Combining parallelism with a lockless per-item log to avoid interleaved output**
```bash
$ cat > convert_all.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p /var/log/convert
for f in /media/*.mov; do
    base=$(basename "$f" .mov)
    ( ffmpeg -i "$f" "/media/converted/${base}.mp4" \
        > "/var/log/convert/${base}.log" 2>&1 ) &
done
wait
echo "Conversion batch complete: $(ls /media/converted | wc -l) files"
EOF
```

## Practice Questions

1. What does `$!` hold, and why must it be captured immediately after backgrounding a job if you plan to `wait` on it specifically later?
2. Write a script that runs 3 independent `tar` backup commands in parallel and only reports success once all three complete.
3. How would you cap concurrency to at most 4 simultaneous jobs when processing 500 files with plain `&`/`wait` (no `xargs`/`parallel`)? What does `wait -n` buy you here?
4. Explain the difference between `xargs -P 4` and `xargs -P 4 -n 1` — when do they behave the same, and when do they diverge?
5. Why should you use `find ... -print0 | xargs -0 ...` instead of `find ... | xargs ...` when filenames might contain spaces or newlines?
6. What capabilities does GNU `parallel` offer that `xargs -P` fundamentally lacks (name at least three)?
7. A colleague's script does `for f in *.csv; do process "$f" & done; wait` on a directory with 50,000 files and the box grinds to a halt. What's wrong, and how do you fix it?
8. How do you retrieve and check the individual exit status of each backgrounded job, rather than just knowing "something failed" from `wait`'s aggregate behavior?
9. Why can output from multiple backgrounded jobs interleave/corrupt on a shared stdout, and what's the standard fix?
10. Design a parallel health-check script (in words or code) that checks 20 hosts, allows at most 5 concurrent SSH connections, and produces a clean pass/fail summary at the end.

## Interview Key Points

- `&` + `wait` is the baseline mechanism — know that `$!` captures the last background PID, and that `wait <pid>` (not bare `wait`) is required to get that specific job's individual exit status.
- `wait -n` (bash 4.3+) is the key primitive for building a manual concurrency-limited worker pool without external tools — a good "how would you throttle parallelism in pure bash" answer.
- `xargs -P N` is the lightweight, always-available (coreutils) option for "run this over a list, N at a time" — know `-I{}` vs `-n 1` and always mention `-print0`/`-0` for filename safety.
- GNU `parallel` is the escalation when you need retries, job logs, preserved output ordering, or remote/distributed execution across hosts — name these differentiators explicitly, they're what interviewers are listening for versus a generic "it's like xargs but better."
- Unbounded parallelism (backgrounding in a loop with no cap) is a real production incident pattern (fork bombs, resource exhaustion, SSH connection storms) — always mention capping concurrency as the senior-level instinct.
- Output interleaving from concurrent jobs sharing stdout is a classic gotcha — the fix is redirecting each job's output to its own file/log, not fighting over a shared stream.
- Be ready to reason about wall-clock savings quantitatively (e.g., "10 independent 5-second tasks run sequentially take 50s; with sufficient parallelism, ~5s") — shows you understand parallelism's actual payoff, not just its syntax.
