# Structured Logging From Scripts

Ad-hoc `echo` statements don't scale past a handful of scripts — timestamps, log levels, and consistent formatting turn script output into something ops tooling (and future-you) can actually parse and trust.

## Explanation

**Why plain `echo` isn't enough in production**:
- No timestamp → can't correlate with other logs during an incident.
- No severity level → can't filter noise ("show me only errors from last night").
- No consistent format → can't grep/parse reliably, can't feed into log aggregators (ELK, Loki, CloudWatch, Splunk).
- Mixed stdout/stderr usage → error messages get lost in normal output or vice versa.

**Core pattern: a `log()` function with level, timestamp, and stream routing**:
```bash
log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    echo "${ts} [${level}] $*" >&2   # logs go to stderr, keeping stdout clean for actual data
}
log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }
```
Key conventions:
- **ISO 8601 timestamps** (`date -Iseconds` or `%Y-%m-%dT%H:%M:%S%z`) — sortable, unambiguous across timezones, and what every log aggregator expects.
- **Log levels** (`DEBUG`/`INFO`/`WARN`/`ERROR`, sometimes `FATAL`) — lets you filter (`grep '\[ERROR\]'`) and lets a `LOG_LEVEL` env var gate verbosity (skip `DEBUG` lines in production).
- **stderr for logs, stdout for data** — a script's actual output/result should go to stdout so it can be piped/captured (`result=$(script.sh)`), while logs/diagnostics go to stderr so they don't contaminate that captured value. This is one of the most common real bugs: a log line accidentally on stdout corrupts a `$(...)` capture.
- **Structured (JSON) logging** — for scripts feeding into a log pipeline (Fluentd, Logstash, CloudWatch Logs Insights), emit one JSON object per line instead of free text, so fields are queryable without regex:
  ```bash
  log_json() {
      printf '{"ts":"%s","level":"%s","msg":"%s"}\n' \
          "$(date -Iseconds)" "$1" "$2" >&2
  }
  ```
- **Log rotation** — long-running scripts writing to a file need rotation (`logrotate`, or a simple size/date check) to avoid unbounded disk growth; don't reinvent this if `logrotate` is available.
- **Correlation/context** — including script name, PID, and (for a multi-step pipeline) a run/request ID makes it possible to trace one execution's full log trail out of a shared log file.

## Hands-On Examples

**1. Minimal leveled logger with ISO 8601 timestamps**
```bash
$ cat > lib_log.sh << 'EOF'
log() {
    local level="$1"; shift
    printf '%s [%s] %s\n' "$(date -Iseconds)" "$level" "$*" >&2
}
log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }
EOF
$ cat > deploy.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source lib_log.sh
log_info "Starting deploy of version 2.3.1"
log_warn "Skipping cache warm-up (flag not set)"
log_error "Health check failed after deploy"
EOF
$ ./deploy.sh
2026-08-08T14:02:11+00:00 [INFO] Starting deploy of version 2.3.1
2026-08-08T14:02:11+00:00 [WARN] Skipping cache warm-up (flag not set)
2026-08-08T14:02:12+00:00 [ERROR] Health check failed after deploy
```

**2. Separating logs (stderr) from actual output (stdout) — critical for `$(...)` capture**
```bash
$ cat > get_version.sh << 'EOF'
#!/usr/bin/env bash
source lib_log.sh
log_info "Fetching latest version tag"
LATEST=$(git describe --tags --abbrev=0)
log_info "Found version: $LATEST"
echo "$LATEST"     # ONLY this goes to stdout
EOF
$ VERSION=$(./get_version.sh)
2026-08-08T14:05:03+00:00 [INFO] Fetching latest version tag     # visible on terminal (stderr), not captured
2026-08-08T14:05:03+00:00 [INFO] Found version: v2.3.1
$ echo "$VERSION"
v2.3.1                                                            # clean, no log noise
```

**3. `LOG_LEVEL` env var gating verbosity (skip DEBUG in prod)**
```bash
$ cat > lib_log2.sh << 'EOF'
declare -A LOG_LEVELS=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
LOG_LEVEL="${LOG_LEVEL:-INFO}"

log() {
    local level="$1"; shift
    (( ${LOG_LEVELS[$level]} >= ${LOG_LEVELS[$LOG_LEVEL]} )) || return 0
    printf '%s [%s] %s\n' "$(date -Iseconds)" "$level" "$*" >&2
}
log_debug() { log "DEBUG" "$@"; }
log_info()  { log "INFO"  "$@"; }
EOF
$ source lib_log2.sh
$ log_debug "Cache key computed: abc123"   # suppressed, LOG_LEVEL=INFO by default
$ LOG_LEVEL=DEBUG bash -c 'source lib_log2.sh; log_debug "Cache key computed: abc123"'
2026-08-08T14:07:44+00:00 [DEBUG] Cache key computed: abc123
```

**4. Logging to both terminal AND a persistent file**
```bash
$ cat > backup.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG_FILE="/var/log/myapp/backup.log"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    local line
    line="$(date -Iseconds) [$1] ${*:2}"
    echo "$line" >&2
    echo "$line" >> "$LOG_FILE"
}
log INFO "Backup started"
tar -czf /backups/app.tar.gz /app
log INFO "Backup finished"
EOF
$ ./backup.sh
2026-08-08T14:10:00+00:00 [INFO] Backup started
2026-08-08T14:10:03+00:00 [INFO] Backup finished
$ tail -2 /var/log/myapp/backup.log
2026-08-08T14:10:00+00:00 [INFO] Backup started
2026-08-08T14:10:03+00:00 [INFO] Backup finished
```

**5. Structured JSON logging for a log-aggregator pipeline**
```bash
$ cat > lib_log_json.sh << 'EOF'
log_json() {
    local level="$1"; shift
    printf '{"ts":"%s","level":"%s","script":"%s","pid":%d,"msg":"%s"}\n' \
        "$(date -Iseconds)" "$level" "${0##*/}" "$$" "$*" >&2
}
EOF
$ cat > sync.sh << 'EOF'
#!/usr/bin/env bash
source lib_log_json.sh
log_json INFO "Sync started for tenant=acme"
log_json ERROR "Sync failed: connection timeout"
EOF
$ ./sync.sh 2>&1 | tee -a /var/log/myapp/sync.jsonl
{"ts":"2026-08-08T14:12:01+00:00","level":"INFO","script":"sync.sh","pid":10432,"msg":"Sync started for tenant=acme"}
{"ts":"2026-08-08T14:12:01+00:00","level":"ERROR","script":"sync.sh","pid":10432,"msg":"Sync failed: connection timeout"}
$ jq -r 'select(.level=="ERROR") | .msg' /var/log/myapp/sync.jsonl
Sync failed: connection timeout
```

**6. Correlation ID for tracing one run across a multi-step pipeline**
```bash
$ cat > pipeline.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
RUN_ID=$(uuidgen)
log() { printf '%s [%s] run=%s %s\n' "$(date -Iseconds)" "$1" "$RUN_ID" "${*:2}" >&2; }

log INFO "Pipeline started"
log INFO "Step 1: extract"
log INFO "Step 2: transform"
log ERROR "Step 3: load failed - disk full"
EOF
$ ./pipeline.sh
2026-08-08T14:15:00+00:00 [INFO] run=7f3a1c22-... Pipeline started
2026-08-08T14:15:00+00:00 [INFO] run=7f3a1c22-... Step 1: extract
2026-08-08T14:15:01+00:00 [INFO] run=7f3a1c22-... Step 2: transform
2026-08-08T14:15:01+00:00 [ERROR] run=7f3a1c22-... Step 3: load failed - disk full
```

**7. Combining logging with `trap ERR` for automatic failure logging**
```bash
$ cat > safe_run.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source lib_log.sh
trap 'log_error "Script failed at line $LINENO running: $BASH_COMMAND"' ERR

log_info "Connecting to database"
psql -c "SELECT 1" nonexistent_db
log_info "This line never runs"
EOF
$ ./safe_run.sh
2026-08-08T14:18:00+00:00 [INFO] Connecting to database
psql: error: connection to server failed
2026-08-08T14:18:00+00:00 [ERROR] Script failed at line 6 running: psql -c "SELECT 1" nonexistent_db
```

**8. Simple size-based log rotation guard (when `logrotate` isn't set up)**
```bash
$ cat > lib_log_rotate.sh << 'EOF'
LOG_FILE="/var/log/myapp/worker.log"
MAX_SIZE=$((10 * 1024 * 1024))   # 10MB

rotate_if_needed() {
    [[ -f "$LOG_FILE" ]] || return 0
    local size
    size=$(stat -c%s "$LOG_FILE")
    if (( size > MAX_SIZE )); then
        mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d%H%M%S)"
        gzip "${LOG_FILE}."*[0-9] 2>/dev/null || true
    fi
}
EOF
$ source lib_log_rotate.sh && rotate_if_needed
$ ls /var/log/myapp/
worker.log.20260807230011.gz
```

## Practice Questions

1. Why should log lines go to stderr rather than stdout in a script whose output is meant to be captured with `$(...)`? Show a concrete bug that occurs if you get this wrong.
2. Write a `log()` function that prefixes every message with an ISO 8601 timestamp and a level (INFO/WARN/ERROR), writing to stderr.
3. How would you implement a `LOG_LEVEL` environment variable that suppresses `DEBUG` messages in production but shows them when a developer sets `LOG_LEVEL=DEBUG`?
4. What's the advantage of emitting logs as single-line JSON objects instead of free-text lines, for a script whose output feeds a log aggregator like Loki or CloudWatch Logs?
5. Design a logging approach that writes to both the terminal (for a human watching) and a persistent log file (for later auditing) without duplicating logic at every call site.
6. What is a correlation/run ID, and why is it valuable when a single script invocation logs many lines interleaved with other concurrent runs of the same script?
7. How would you combine a `trap ... ERR` with your logging function so that any unexpected command failure is automatically logged with its line number, without manually adding error-logging to every command?
8. Why is `date -Iseconds` (or explicit `%Y-%m-%dT%H:%M:%S%z`) preferred over a bare `date` call for log timestamps in a distributed/multi-timezone environment?
9. A script's log file grows unbounded on a long-running host and eventually fills the disk. What are two ways to address this (one using existing OS tooling, one hand-rolled)?
10. Given a JSON-lines log file produced by a script, write a `jq` command to extract only ERROR-level messages from the last hour.

## Interview Key Points

- **stdout for data, stderr for logs** is the single most important convention here — interviewers will often probe with "what breaks if you `echo` a log line without redirecting to stderr in a script that's meant to be used inside `$(...)`."
- Always be ready to name the four things a production log line needs: timestamp (ISO 8601), level, message, and (ideally) source/context — a bare `echo "doing thing"` is a red flag in review.
- Log levels + a `LOG_LEVEL` gate is the standard way scripts avoid being either too noisy (DEBUG everywhere) or too silent (nothing when you need to diagnose) — know how to implement the gate with a lookup table/associative array.
- JSON-lines logging is the expected answer when the conversation turns to "this script's output needs to go into ELK/Loki/CloudWatch" — plain text requires fragile regex parsing downstream, structured logs don't.
- Correlation/run IDs (`uuidgen`, or PID+timestamp) matter once you're debugging concurrent or scheduled runs of the same script sharing one log stream — a good scenario question probes whether you'd think to add one.
- Combining `trap ... ERR` with a logging function is a strong "production hardening" answer — it guarantees failures get logged with context (line number, failing command) without littering every command with manual error handling.
- Don't hand-roll log rotation if `logrotate` is available on the box — know it exists and mention it before describing your own size-check fallback, showing you'd reach for the standard tool first.
