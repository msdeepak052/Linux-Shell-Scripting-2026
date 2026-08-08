# Health-Check, Monitoring & Alerting Scripts

Hand-rolled bash scripts that check CPU, memory, disk, and service health and fire an alert when a threshold is crossed — the glue layer between raw Linux metrics and a real alerting pipeline (Slack, PagerDuty, email) when you don't have (or fully trust) Prometheus/Nagios yet.

## Explanation

### What a "health check script" actually needs to do

A production health-check script is not just "print some numbers." It has four jobs:
1. **Sample a metric** (CPU load, memory %, disk %, a systemd unit's state, an HTTP endpoint).
2. **Compare it against a threshold** — usually with warning and critical tiers, not just one cutoff.
3. **Decide what "alerting" means** — exit code for a monitoring system to poll, a message pushed to Slack/email, or both.
4. **Avoid alert fatigue** — don't re-alert every minute for the same ongoing condition; track state so you only alert on transitions (OK→WARN, WARN→CRIT) or with a cooldown.

### Sourcing metrics without external tools

You want these scripts to run on a bare minimal box with no `sysstat`/`jq` guaranteed, so lean on things that ship everywhere:

- **CPU**: `/proc/loadavg` (1/5/15 min load averages) is the simplest, most portable source — no parsing of `top`'s screen-refresh output needed. For per-core % you'd read `/proc/stat` deltas, but load average normalized by `nproc` is usually good enough for a threshold check.
- **Memory**: `free -m` or, more scriptable, `/proc/meminfo` directly (`MemAvailable`, `MemTotal`) — `MemAvailable` (not `MemFree`) is the correct "how much can I actually use" number since it accounts for reclaimable cache.
- **Disk**: `df -h` / `df -P` (POSIX output format — stable column layout, avoid plain `df -h` in scripts because column widths shift; `-P` guarantees one line per filesystem, no wrapping).
- **Service state**: `systemctl is-active <unit>` / `systemctl is-failed <unit>` — exit codes are your friend here, no text-parsing needed.
- **App-level health**: `curl -sf -o /dev/null -w "%{http_code}"` against a `/healthz` endpoint.

### Alerting mechanisms — from cheapest to most robust

| Mechanism | How | When to use |
|---|---|---|
| Exit code only | `exit 0/1/2` | Script is invoked BY a monitoring system (Nagios/Icinga plugin convention: 0=OK,1=WARN,2=CRIT,3=UNKNOWN) |
| Local log + `logger` | Write to syslog/journal | Feeds into a centralized log pipeline (ELK, Loki) that has its own alerting rules |
| Webhook (Slack/Teams) | `curl -X POST` a JSON payload to an incoming webhook URL | Fast, human-visible, easy to bootstrap without a full alerting stack |
| `mail`/`sendmail` | `mail -s "subject" you@company.com` | Legacy but still common for cron-driven infra alerts |
| PagerDuty Events API | `curl` to Events API v2 with a routing key | Needs to page someone, not just notify a channel |

### Which one should you actually use? (Decision rule)

| Situation | Use |
|---|---|
| Script runs as a plugin under Nagios/Icinga/Zabbix | Standard exit codes (0/1/2/3) — let the monitoring system own notification routing |
| Standalone script on a cron/systemd timer, small team | Slack webhook — cheapest to set up, immediately visible, no separate paging infra |
| Needs to wake someone up at 3am | PagerDuty/Opsgenie Events API — Slack messages get missed, pages don't |
| You already run Prometheus | **Don't hand-roll this at all** — export the metric (node_exporter or a custom textfile collector) and let Alertmanager own thresholds/routing/dedup |

**Bottom line**: hand-rolled bash health-check scripts are for the gap before (or alongside) a real metrics stack — the moment you have Prometheus/Grafana/Alertmanager in place, threshold logic belongs there, not scattered across cron scripts, because Alertmanager gives you dedup, silencing, and escalation for free.

### State tracking to avoid alert spam

Without state, a script re-sent every 5 minutes by cron will page you every 5 minutes while disk stays at 95%. The standard fix: write a small state/lock file recording the last known status, and only alert on a state **transition**, or gate re-alerts with a cooldown timestamp.

## Hands-On Examples

> Multi-line `if`/`while`/heredoc blocks below show bash's `>` continuation prompt when typed interactively — you don't type the `>` yourself, bash prints it while waiting for the block to close (`fi`, `done`, `EOF`).

**1. Basic CPU load check using `/proc/loadavg`**
```bash
$ cat /proc/loadavg
2.15 1.87 1.42 3/482 28193

$ cores=$(nproc)
$ load1=$(awk '{print $1}' /proc/loadavg)
$ echo "Load: $load1, Cores: $cores"
Load: 2.15, Cores: 4

$ awk -v load="$load1" -v cores="$cores" 'BEGIN { if (load/cores > 0.8) print "HIGH"; else print "OK" }'
OK
```

**2. Memory check using `MemAvailable` (the correct field, not `MemFree`)**
```bash
$ grep -E 'MemTotal|MemAvailable' /proc/meminfo
MemTotal:       16345620 kB
MemAvailable:    2103244 kB

$ awk '/MemTotal/ {total=$2} /MemAvailable/ {avail=$2} END {printf "Used: %.1f%%\n", (1-avail/total)*100}' /proc/meminfo
Used: 87.1%
```

**3. Disk check with `df -P` — portable, stable parsing**
```bash
$ df -P /var /
Filesystem     1024-blocks     Used Available Capacity Mounted on
/dev/nvme0n1p2   103080160 91234816   6612456      94% /
/dev/nvme0n1p3    52403200 49821760   2054016      97% /var

$ df -P /var | awk 'NR==2 {gsub("%","",$5); print $5}'
97
```

**4. Service health check with correct systemd exit-code use**
```bash
$ systemctl is-active nginx; echo "exit: $?"
active
exit: 0

$ systemctl is-active postgresql; echo "exit: $?"
failed
exit: 3

$ systemctl is-failed postgresql
failed
```

**5. Combined multi-check script with tiered thresholds and Slack alerting**
```bash
$ cat > /usr/local/bin/health-check.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

WEBHOOK="https://hooks.slack.com/services/T000/B000/XXXXXXXXXXXX"
HOSTNAME=$(hostname)
STATE_FILE="/var/tmp/health-check.state"
ISSUES=()

alert_slack() {
    curl -sf -X POST -H 'Content-type: application/json' \
        --data "{\"text\":\"[$HOSTNAME] $1\"}" "$WEBHOOK" > /dev/null
}

# CPU
load1=$(awk '{print $1}' /proc/loadavg)
cores=$(nproc)
cpu_pct=$(awk -v l="$load1" -v c="$cores" 'BEGIN{printf "%.0f", (l/c)*100}')
(( cpu_pct >= 90 )) && ISSUES+=("CRITICAL: load ${cpu_pct}% of capacity")

# Memory
mem_pct=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%.0f", (1-a/t)*100}' /proc/meminfo)
(( mem_pct >= 90 )) && ISSUES+=("CRITICAL: memory at ${mem_pct}%")

# Disk (all mounted real filesystems)
while read -r pct mount; do
    (( pct >= 90 )) && ISSUES+=("CRITICAL: ${mount} at ${pct}% disk usage")
done < <(df -P -x tmpfs -x devtmpfs | awk 'NR>1 {gsub("%","",$5); print $5, $6}')

# Services
for svc in nginx postgresql; do
    systemctl is-active --quiet "$svc" || ISSUES+=("CRITICAL: $svc is not active")
done

if (( ${#ISSUES[@]} > 0 )); then
    prev_state=$(cat "$STATE_FILE" 2>/dev/null || echo "OK")
    if [[ "$prev_state" != "ALERTING" ]]; then
        for issue in "${ISSUES[@]}"; do
            alert_slack "$issue"
        done
        echo "ALERTING" > "$STATE_FILE"
    fi
    exit 2
else
    echo "OK" > "$STATE_FILE"
    exit 0
fi
EOF
$ chmod +x /usr/local/bin/health-check.sh
$ ./health-check.sh; echo "exit: $?"
exit: 2
```
This demonstrates the transition-only alerting pattern: it only actually POSTs to Slack the first time it goes from OK to alerting, then stays quiet on subsequent cron runs until it recovers — preventing a wall of duplicate pages while disk stays pinned at 94%.

**6. Real incident-style check: catching a runaway process before OOM**
```bash
$ ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%mem | head -5
    PID    PPID CMD                         %MEM  %CPU
  28401       1 java -jar batch-etl.jar     42.3  95.1
   1122       1 /usr/sbin/mysqld            18.7   4.2
   9981       1 nginx: worker process        0.4   0.1
   9982    9981 nginx: worker process        0.4   0.0

$ # A targeted alert: warn if any single process exceeds 40% of RAM
$ ps -eo pid,cmd,%mem --sort=-%mem --no-headers | awk '$3+0 > 40 {print "WARN: PID "$1" ("$2") using "$3"% memory"}'
WARN: PID 28401 (java) using 42.3% memory
```

**7. HTTP endpoint health check with timeout and retry**
```bash
$ cat > check_endpoint.sh << 'EOF'
#!/usr/bin/env bash
url="http://localhost:8080/healthz"
for attempt in 1 2 3; do
    code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 3 "$url" 2>/dev/null) && break
    sleep 2
done
if [[ "$code" == "200" ]]; then
    echo "OK: $url returned 200"
    exit 0
else
    echo "CRITICAL: $url unreachable or unhealthy after 3 attempts"
    exit 2
fi
EOF
$ ./check_endpoint.sh
CRITICAL: http://localhost:8080/healthz unreachable or unhealthy after 3 attempts
```

## Practice Questions

1. Why should a memory-usage check read `MemAvailable` from `/proc/meminfo` instead of `MemFree`? What would go wrong if you used `MemFree` on a box with heavy page-cache usage?
2. Write a disk-check one-liner using `df -P` that prints only filesystems above 90% used, excluding `tmpfs`/`devtmpfs` pseudo-filesystems. Why exclude those?
3. A cron-driven alerting script pages the on-call engineer every 5 minutes for the same ongoing disk-full condition. What's the fix, and how would you implement "alert only on state transition" in bash?
4. What's the difference between `systemctl is-active` and `systemctl is-failed`, and why is checking exit codes more reliable than grepping `systemctl status` output?
5. Design (in words, then a short script) a health check that distinguishes WARNING (e.g., 80% disk) from CRITICAL (95% disk) tiers, and explain why a single threshold is usually insufficient in production.
6. You have Prometheus + Alertmanager already running. Should you still write bash health-check cron scripts for CPU/memory/disk? Justify your answer.
7. Write a check that flags any single process consuming more than 40% of system memory, using `ps` output — why is this a useful early-warning signal ahead of an OOM kill?
8. What Nagios/Icinga plugin exit-code convention should a script follow (0/1/2/3) if it's meant to be consumed by that monitoring system, and why does exit code 3 (UNKNOWN) matter as much as 1/2?
9. A health-check script uses `curl -s` (no `-f`) to hit an endpoint and only checks `$?`. Why is this insufficient to detect a failing service, and what should it check instead?
10. Explain the trade-off between a Slack webhook alert and a PagerDuty Events API alert for a disk-full condition on a non-critical dev box vs. a production database host.

## Real Interview Questions (Company-Attributed)

- "Write a script to check disk usage and send an alert if it exceeds a threshold." — asked at *Nextturn*
- "Create a script to monitor disk usage; if it exceeds 80%, log the details to a file and send an alert email." — asked at *an unnamed company (via community-sourced interview notes)*
- "Write a shell script that checks if a service is running, restarts it if not, and logs the event." — asked at *an unnamed company (via community-sourced interview notes)*
- "Write a script to monitor a service and restart it if it fails, including proper logging." — asked at *LTIMindtree*
- "How do you handle disk/CPU alerting?" — asked at *Infosys*
- "How do you check the server's current system load?" — asked at *an unnamed company (via community-sourced interview notes)*
- "What command do you use to get the number of CPU cores on a machine?" — asked at *Deloitte*

## Interview Key Points

- **State-transition alerting is the single most important "senior" signal** in this topic — anyone can write a threshold check; distinguishing "alert once on OK→CRIT" from "alert every run" shows you've actually operated something in production and dealt with alert fatigue.
- Know **`MemAvailable` vs `MemFree`** cold — it's a classic "gotcha" because `MemFree` looks intuitive but is wrong; Linux aggressively uses free RAM for page cache, which is reclaimable, so `MemFree` alone dramatically overstates memory pressure.
- Prefer `/proc/loadavg`, `/proc/meminfo`, `df -P` over parsing `top`/`free -h`/plain `df -h` — the former are stable, machine-parseable formats; the latter are meant for humans and their column widths/wrapping can silently break `awk`/`cut` parsing.
- Know the **Nagios/Icinga plugin exit-code convention** (0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN) — it's the de facto standard even outside Nagios itself and interviewers use it to check you understand monitoring integration, not just scripting.
- Be ready to argue **when NOT to hand-roll this** — the mature answer to "how would you monitor CPU/memory/disk" is "export metrics to Prometheus and let Alertmanager handle thresholds/dedup/routing," with bash scripts reserved for gaps, one-off boxes, or bootstrapping before that stack exists.
- Tiered thresholds (WARN vs CRIT) and multiple consecutive-check confirmation before alerting (avoiding a single noisy spike triggering a page) are both common follow-up probes — have an answer ready for "how do you avoid false positives from a momentary CPU spike."
- Know why `curl -sf` (fail on HTTP error codes) plus `--max-time` (bound the hang) plus a retry loop is the correct pattern for an HTTP health check — a bare `curl` without `-f` returns exit 0 even on a 500 response because curl itself succeeded at making the request.
