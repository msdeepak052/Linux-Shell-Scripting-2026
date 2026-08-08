# Exit Codes & Basic Error Checks (`$?`, `||`, `&&`)

Every command in Linux reports success or failure through its exit code — production scripts live or die by whether you actually check it.

## Explanation

**Exit code convention**: `0` = success, `1-255` = failure (specific meaning varies per command). Every script/function also has its own exit code, either the last command's status, or explicitly via `exit N` / `return N`.

**`$?`** holds the exit status of the **immediately preceding command** — it gets overwritten by literally anything you run next, including `echo`. So it must be captured right away:
```bash
some_command
rc=$?              # capture immediately
echo "Exit code was: $rc"
```

**Short-circuit operators**:
```bash
command1 && command2    # command2 runs ONLY IF command1 succeeded (exit 0)
command1 || command2    # command2 runs ONLY IF command1 FAILED (non-zero)
```
Common idiom: `mkdir /data || { echo "failed to create dir" >&2; exit 1; }`

**`exit N`** in a script sets its own final exit status (visible to whoever called it, e.g., as `$?` in a parent script, or in cron/systemd job status). Valid range is 0-255 (wraps around above that).

**Script-wide safety flags** (huge for production scripts):
```bash
set -e            # exit immediately if ANY command fails (careful: some exceptions apply)
set -u            # error on use of an undefined variable
set -o pipefail   # a pipeline's exit code = the last FAILING command, not just the last command
set -euo pipefail # the common combined "strict mode" header
```

## Hands-On Examples

**1. Basic `$?` check**
```bash
$ grep "nginx" /etc/passwd
$ echo $?
1

$ systemctl is-active nginx
active
$ echo $?
0

$ systemctl is-active bogus_service
unknown
$ echo $?
3
```

**2. `&&` / `||` for lightweight control flow**
```bash
$ mkdir -p /tmp/deploy_$$ && echo "Directory ready" || echo "Failed to create dir"
Directory ready

$ cd /nonexistent/path 2>/dev/null || echo "Directory doesn't exist, aborting"
Directory doesn't exist, aborting
```

**3. Real-world: validating a critical step before continuing**
```bash
$ cat > deploy.sh << 'EOF'
#!/bin/bash
echo "Pulling latest image..."
docker pull myapp:latest
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to pull image, aborting deploy" >&2
    exit 1
fi
echo "Starting container..."
docker run -d myapp:latest
EOF
```

**4. `set -e` — fail fast, and its exceptions**
```bash
$ cat > strict.sh << 'EOF'
#!/bin/bash
set -e
echo "Step 1"
false                    # this fails — set -e kills the script HERE
echo "Step 2 (never reached)"
EOF
$ ./strict.sh
Step 1
$ echo $?
1

# Exception: set -e does NOT trigger inside an if/while condition, or before && / ||
$ cat > strict_exception.sh << 'EOF'
#!/bin/bash
set -e
if false; then           # false here does NOT trigger set -e — it's a condition
    echo "unreachable"
fi
echo "Still running after 'if false'"
false || echo "handled, still running"
EOF
$ ./strict_exception.sh
Still running after 'if false'
handled, still running
```

**5. `set -u` — catching typos in variable names**
```bash
$ cat > nounset.sh << 'EOF'
#!/bin/bash
set -u
echo "Deploying to $enviroment"   # typo: should be $environment
EOF
$ ./nounset.sh
./nounset.sh: line 3: enviroment: unbound variable
$ echo $?
1
```
Without `set -u`, this would silently print "Deploying to " (empty string) — a very common source of production bugs from typo'd variable names.

**6. `set -o pipefail` — catching failures hidden inside a pipeline**
```bash
$ false | echo "this always runs"
this always runs
$ echo $?
0                          # WRONG — only reflects echo's status, false's failure is HIDDEN

$ set -o pipefail
$ false | echo "this always runs"
this always runs
$ echo $?
1                          # CORRECT — pipefail surfaces the failing command's status

# Real bug this catches: a failed command piped into something that "succeeds"
$ grep "ERROR" /nonexistent/log.txt | wc -l
0
grep: /nonexistent/log.txt: No such file or directory
$ echo $?
0                          # without pipefail: wc succeeded, so pipeline "succeeded" — masking the real error
```

**7. Combined strict-mode header — the standard production script opener**
```bash
$ cat > production.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Starting backup"
tar -czf /backups/app_$(date +%Y%m%d).tar.gz /app/data \
    || { log "ERROR: backup failed"; exit 1; }
log "Backup completed successfully"
EOF
```

**8. Custom exit codes for different failure types (useful for monitoring/alerting integration)**
```bash
$ cat > healthcheck.sh << 'EOF'
#!/bin/bash
[[ -f /etc/myapp/config.yml ]] || { echo "Config missing"; exit 2; }
systemctl is-active --quiet myapp || { echo "Service down"; exit 3; }
curl -sf http://localhost:8080/health > /dev/null || { echo "Health endpoint failing"; exit 4; }
echo "All checks passed"
exit 0
EOF
$ ./healthcheck.sh; echo "Exit code: $?"
All checks passed
Exit code: 0
```
Distinct exit codes let a caller (monitoring system, orchestrator) distinguish *why* a check failed, not just that it failed.

## Practice Questions

1. Why does `command; echo $?` sometimes give unexpected results if you insert another command (even something as simple as `echo "done"`) between them? Rewrite it safely capturing the exit code into a variable.
2. What's the difference in behavior between `cmd1 && cmd2` and `cmd1; cmd2`? Give an example where using `;` instead of `&&` causes a real bug.
3. Explain what `set -e` does, and describe ONE scenario where a command fails but `set -e` does NOT stop the script (i.e., a known exception to `set -e`).
4. What problem does `set -o pipefail` solve? Show a pipeline where its absence would hide a real failure.
5. Write a script header enabling "strict mode" (`set -euo pipefail`) and explain what each of the three flags individually protects against.
6. What's the exit code range in bash, and what happens if you do `exit 300`?
7. Write a health-check script that returns different exit codes (2, 3, 4) for different failure conditions (missing config, service down, endpoint unresponsive) versus 0 for success, and explain why distinct codes are useful for a caller like a monitoring system.
8. What does `grep "pattern" file.txt || true` accomplish, and when would you deliberately want to suppress a non-zero exit from `grep` under `set -e`?
9. A script uses `set -u` and immediately breaks on `$1` when no arguments were passed. What's happening, and how do you safely check for a missing argument under `set -u`?
10. Given `cmd_a | cmd_b | cmd_c`, and only `cmd_b` fails, what does `$?` report WITHOUT `pipefail`, and what does it report WITH `pipefail` enabled?

## Real Interview Questions (Company-Attributed)

- "What's the difference between single ampersand (`&`) and double ampersand (`&&`) in shell scripting?" — asked at *Sonata Software*

## Interview Key Points

- **`$?` is only valid immediately after the command it refers to** — capture it into a variable right away if you need it later; this is a very common "spot the bug" interview question.
- `set -euo pipefail` ("strict mode" / "unofficial bash strict mode") is close to a mandatory answer when asked "how do you write robust production bash scripts" — know all three flags and what each specifically guards against.
- Know the **exceptions to `set -e`**: it does NOT trigger inside `if`/`while`/`until` conditions, before `&&`/`||`, or inside a command whose result is negated with `!` — a senior-level nuance many candidates miss.
- `pipefail` is essential and non-obvious: without it, a pipeline's exit code is only the **last** command's status, silently swallowing earlier failures — a classic real-world production bug source (e.g., `command | tee log.txt` masking `command`'s failure).
- Distinct, meaningful custom exit codes (not just 0/1 everywhere) are a mark of production-quality scripting — useful for integrating with monitoring/alerting/orchestration systems that branch on specific codes.
- `command || true` (or `command || :`) is the standard way to intentionally allow a command to fail without killing a `set -e` script — know this pattern for "expected to sometimes fail" commands like `grep` with no matches.
- Exit codes 126 (not executable), 127 (command not found), and 128+signal (killed by signal, e.g. 137 = 128+9 = SIGKILL, often OOM-killed) are commonly asked about — know these off the top of your head.
