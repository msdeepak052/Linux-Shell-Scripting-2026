# Runbooks & Incident-Response Automation

A runbook is a step-by-step, executable-quality guide for handling a known failure mode — the goal is that a mid-level on-call engineer at 3am, half-awake, can follow it and reach the same outcome a senior engineer would.

## Explanation

**What makes something a real runbook vs a wiki page that looks like one**: a real runbook is *specific and executable* — exact commands, exact expected output, exact decision branches ("if X, go to step 4; if Y, escalate") — not prose like "check if the database is healthy." A vague runbook fails exactly when it matters most: under pressure, at 3am, with an unfamiliar engineer on-call.

**Standard runbook anatomy:**
1. **Trigger** — which alert fires this, and what it means literally (not just the alert name).
2. **Impact / severity** — what's actually broken for users right now, so on-call can triage against other concurrent incidents.
3. **Diagnosis steps** — the exact commands to run, in order, with what each *possible* output means (branches).
4. **Remediation** — the exact fix commands, including any pre-checks/guardrails before running them.
5. **Verification** — how to confirm the fix actually worked (not just "ran the command and it didn't error").
6. **Escalation path** — who to page and when, if diagnosis doesn't match any known branch.
7. **Rollback** — how to undo the remediation if it makes things worse.

**Manual runbook vs automated runbook vs full auto-remediation** — these are three different maturity levels, not one thing:
- **Manual runbook**: a document. A human reads it and types commands themselves. Slowest, but maximal human judgment at every step.
- **Semi-automated (ChatOps-style)**: a human triggers a pre-written script (often from a Slack command or a "run" button in an incident tool) after confirming diagnosis — the diagnosis is still human-reviewed, the *execution* is automated to avoid typo/fat-finger risk.
- **Full auto-remediation**: a system detects the condition and remediates with zero human involvement (e.g., auto-restart a crashed process, auto-scale on high load). Fastest, but **only appropriate for well-understood, low-blast-radius, reversible actions** — this is where a badly designed "self-healing" script becomes the incident (e.g., an automated restart loop that keeps killing a service that's actually failing for an unrelated reason, and the restarts themselves generate a thundering herd on startup).

### Should this remediation step be automated? (Decision rule)

| Criterion | Keep manual (human executes) | Safe to automate |
|---|---|---|
| **Blast radius if wrong** | Large (data loss, whole-fleet impact) | Small, contained to one instance/pod |
| **Reversibility** | Hard/impossible to undo (deleting data, force-pushing config) | Trivially reversible (restart, scale up, clear a cache) |
| **Frequency** | Rare, novel situations | Recurring, well-understood failure signature |
| **Confidence in diagnosis** | Ambiguous — multiple possible root causes look the same | Diagnosis is unambiguous and cheap to confirm before acting |
| **Historical false-positive rate of the trigger** | High (alert has cried wolf before) | Low, alert has been reliable |

**Bottom line: automate the boring, frequent, reversible, low-blast-radius steps (restart a stuck worker, roll a stuck deploy back, clear a known-bad cache key) and keep a human explicitly in the loop for anything with a large or irreversible blast radius** — and always build in a circuit breaker (max N auto-remediation attempts per time window) so automation can't loop itself into a bigger outage.

**Guardrails every remediation script should have**: a `--dry-run` mode that prints what it *would* do without doing it; a rate limit / circuit breaker on repeated triggers; structured logging of every action taken (for the postmortem); and a way to page a human if the automated fix itself fails.

## Hands-On Examples

**1. A runbook stored as a script header + inline comments — diagnosis and remediation, not just prose**
```bash
$ cat runbooks/high-memory-oom.sh
#!/usr/bin/env bash
# RUNBOOK: high-memory-oom.sh
# TRIGGER: PagerDuty alert "node-memory-90pct" fires
# IMPACT: risk of OOM-killer terminating random processes on the host
# DIAGNOSIS: identify the top memory consumer before doing anything
set -euo pipefail
echo "== Top 5 memory consumers =="
ps -eo pid,ppid,cmd,%mem,rss --sort=-%mem | head -6
```
```bash
$ ./runbooks/high-memory-oom.sh
== Top 5 memory consumers ==
    PID    PPID CMD                         %MEM     RSS
  18422       1 java -jar batch-worker.jar   34.2 5603248
   9911       1 /usr/bin/postgres            12.1 1982004
   4102       1 nginx: worker process         0.8  131920
```
The runbook's diagnosis step already tells the on-call engineer the answer here — `batch-worker.jar` is the outlier, not a slow memory leak across the whole fleet.

**2. Circuit-breaker pattern — auto-remediation that refuses to loop itself into a bigger outage**
```bash
$ cat > auto_restart_guarded.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
SERVICE="myapp"
STATE_FILE="/var/run/myapp_restart_count"
MAX_RESTARTS=3
WINDOW_SECONDS=1800   # 30 minutes

now=$(date +%s)
if [[ -f "$STATE_FILE" ]]; then
    read -r count window_start < "$STATE_FILE"
    if (( now - window_start > WINDOW_SECONDS )); then
        count=0; window_start=$now   # window expired, reset
    fi
else
    count=0; window_start=$now
fi

if (( count >= MAX_RESTARTS )); then
    echo "CIRCUIT BREAKER OPEN: $count restarts in the last 30m — paging on-call instead of restarting again"
    exit 1
fi

echo "Restarting $SERVICE (attempt $((count+1))/$MAX_RESTARTS this window)"
systemctl restart "$SERVICE"
echo "$((count+1)) $window_start" > "$STATE_FILE"
EOF
$ ./auto_restart_guarded.sh
Restarting myapp (attempt 1/3 this window)
$ ./auto_restart_guarded.sh
Restarting myapp (attempt 2/3 this window)
$ ./auto_restart_guarded.sh
Restarting myapp (attempt 3/3 this window)
$ ./auto_restart_guarded.sh
CIRCUIT BREAKER OPEN: 3 restarts in the last 30m — paging on-call instead of restarting again
```

**3. `--dry-run` guardrail on a real remediation script**
```bash
$ cat > clear_stuck_queue.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

stuck_msgs=$(redis-cli -h queue.internal LLEN dead_letter_queue)
echo "Found $stuck_msgs messages in dead_letter_queue"

if $DRY_RUN; then
    echo "[DRY RUN] Would purge dead_letter_queue ($stuck_msgs messages)"
else
    redis-cli -h queue.internal DEL dead_letter_queue
    echo "Purged dead_letter_queue"
fi
EOF
$ ./clear_stuck_queue.sh --dry-run
Found 4821 messages in dead_letter_queue
[DRY RUN] Would purge dead_letter_queue (4821 messages)
```
Every destructive remediation script in a runbook repo should support `--dry-run` — it lets a nervous on-call engineer (or the interviewer, asking "how do you know this script is safe to run") verify intent before it does anything irreversible.

**4. ChatOps-triggered remediation — human confirms diagnosis, execution is automated**
```bash
$ cat > slack_webhook_handler.sh << 'EOF'
#!/usr/bin/env bash
# Invoked by a Slack slash-command /restart-worker <name>, after a human
# has already looked at the diagnosis output posted by the alert.
set -euo pipefail
worker="$1"
echo "Restarting worker: $worker (triggered by ${SLACK_USER:-unknown} via ChatOps)"
kubectl rollout restart deployment/"$worker" -n workers
kubectl rollout status deployment/"$worker" -n workers --timeout=60s
EOF
$ SLACK_USER=deepak ./slack_webhook_handler.sh payment-worker
Restarting worker: payment-worker (triggered by deepak via ChatOps)
deployment "payment-worker" successfully rolled out
```

**5. Automatic diagnostics capture BEFORE remediation — preserving evidence for the postmortem**
```bash
$ cat > pre_remediation_snapshot.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
INCIDENT_ID="${1:?usage: pre_remediation_snapshot.sh <incident-id>}"
DIR="/var/log/incidents/${INCIDENT_ID}"
mkdir -p "$DIR"

ps aux > "$DIR/ps_aux.txt"
journalctl -u myapp -n 500 --no-pager > "$DIR/journal_myapp.txt"
ss -tlnp > "$DIR/sockets.txt"
free -h > "$DIR/memory.txt"
echo "Snapshot captured under $DIR — safe to proceed with remediation"
EOF
$ ./pre_remediation_snapshot.sh INC-4821
Snapshot captured under /var/log/incidents/INC-4821 — safe to proceed with remediation
```
This is a deliberate habit senior engineers build in: **capture evidence before you fix it**, because the remediation itself (a restart, a rollback) often destroys the exact state you'd need later to find the real root cause.

**6. Escalation branch written directly into the script's output, not left to memory**
```bash
$ ./runbooks/db-replication-lag.sh
Replication lag: 340s (threshold: 60s)
Checked: replica disk I/O — normal
Checked: network between primary/replica — normal
No known cause matched. ESCALATE to #database-oncall — this runbook's diagnosis
tree does not cover lag caused by something other than I/O or network;
do not attempt manual intervention on replication state without a DBA.
```

## Practice Questions

1. What separates a genuinely useful runbook from "a wiki page describing the general idea of how to fix something"? Give a concrete example of a vague step and rewrite it as an executable one.
2. Walk through the difference between a manual runbook, a semi-automated (ChatOps) runbook, and full auto-remediation. Give a real example failure mode for each that's appropriate to automate at that level and one that isn't.
3. Design a circuit breaker for an auto-restart script: what state does it need to track, and what should happen once the breaker trips?
4. Why should a destructive remediation script almost always support `--dry-run`? What would you tell an interviewer who asks "how do you know your automated runbook won't make things worse"?
5. Explain why capturing diagnostic evidence (logs, process list, sockets) BEFORE running a remediation step matters for the postmortem process, with a concrete example of evidence a restart would destroy.
6. You inherit an on-call rotation with a runbook that says "restart the service if memory usage is high." What's wrong with this runbook, and how would you rewrite it into an executable version?
7. A fully automated remediation script has been quietly restarting a crash-looping service every 5 minutes for 6 hours, and the real root cause (a bad deploy) was never surfaced to a human. What guardrail was missing, and how would you have designed it?
8. What's the tradeoff between "automate everything for speed" and "keep humans in the loop for judgment" during incident response — and where do you personally draw that line for a payments system vs an internal analytics dashboard?

## Interview Key Points

- **Runbooks must be executable, not descriptive** — "check if the DB is healthy" fails under 3am pressure; "run `pg_isready -h db-primary`, expect `accepting connections`" doesn't. Interviewers listen for this specificity.
- **Know the three maturity levels** (manual → ChatOps/semi-automated → full auto-remediation) and be ready to justify which level fits which failure mode using blast radius and reversibility, not "more automation is always better."
- **Circuit breakers are the single most-checked-for detail** when discussing auto-remediation — an unguarded auto-restart loop is one of the most common "automation caused the incident" real-world stories, and interviewers are listening for whether you'd build in a cap.
- **`--dry-run` on destructive scripts** is a cheap, concrete answer to "how do you build trust in automation" — always mention it.
- **Capture evidence before remediating** — this is a subtle but senior-level point: the fix often destroys the forensic trail needed for root-causing, so snapshot state first.
- **Blameless postmortems tie directly to runbook quality**: a good postmortem process treats "the runbook was wrong/missing a branch" as an action item to fix the runbook, not a reason to blame the on-call engineer who followed it.
- Escalation paths must be an explicit part of the runbook (who, and under what unmatched condition) — "the runbook didn't cover this case" is a completely normal, expected outcome, and the runbook should say so explicitly rather than silently dead-ending.
