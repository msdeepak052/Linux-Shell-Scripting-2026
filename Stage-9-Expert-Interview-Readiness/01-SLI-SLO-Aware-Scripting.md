# SLI/SLO-Aware Scripting & Health Checks

Health-check and monitoring scripts are worthless if they don't measure the same things your reliability targets are defined against — this is where SRE theory (SLI/SLO/error budgets) has to turn into actual bash.

## Explanation

**The vocabulary, precisely (interviewers check this first):**
- **SLI (Service Level Indicator)**: a *quantitative measurement* of some aspect of service behavior — e.g., "% of HTTP requests completed in under 300ms," "% of requests returning non-5xx." An SLI is a ratio: `good events / valid events`.
- **SLO (Service Level Objective)**: a *target* for an SLI over a time window — e.g., "99.9% of requests succeed, measured over a rolling 28 days."
- **SLA (Service Level Agreement)**: an SLO with a *contractual consequence* attached (refunds, credits) if missed. SLAs are usually looser than internal SLOs, so you breach the SLO internally before you ever breach the customer-facing SLA.
- **Error budget**: `1 - SLO`. A 99.9% availability SLO gives you a 0.1% error budget — roughly 43 minutes of full downtime per 30 days (or equivalent partial degradation). The error budget is what lets a script make a *policy* decision ("do we page someone or just log it?"), not just a pass/fail check.

**Why this matters for scripting specifically**: a naive health check just asks "is it up?" (binary). An SLI/SLO-aware check asks "is it up **within the terms we promised**?" — which means measuring *latency distribution* and *error rate*, not just a single boolean, and it means thinking about **burn rate** (how fast you're consuming the error budget) rather than just current-instant state.

### From SLI to a script: what actually gets measured

Two common measurement strategies, and a script implements one of them:
- **Blackbox/synthetic probing**: the script itself acts as a client — `curl` a real endpoint, time it, check the status code. Simple, catches things real users would hit, but only samples what you probe.
- **Metrics-derived**: the script queries an existing time-series store (Prometheus, CloudWatch) for the SLI that's already being computed from real traffic, and just evaluates it against the SLO threshold. More accurate (real traffic, not synthetic), but depends on instrumentation already existing.

**Health check exit-code convention** (Nagios/Icinga-style, still the de facto standard integrated into most monitoring stacks):

| Exit code | Meaning |
|---|---|
| `0` | OK — within SLO |
| `1` | WARNING — degraded, approaching SLO breach, not yet critical |
| `2` | CRITICAL — SLO breached / service down |
| `3` | UNKNOWN — the check itself couldn't determine status (script bug, dependency unreachable) |

**Burn rate** = (error budget consumed) / (time elapsed as a fraction of the SLO window). A burn rate of 1 means "consuming budget exactly on pace to exhaust it right at window end." A burn rate of 14.4 over 1 hour is the classic Google SRE "fast burn" alert — it means at this rate you'd exhaust a 30-day budget in about 2 days, which is worth paging a human immediately. A burn rate of 1 sustained is worth a ticket, not a page. **Multi-window, multi-burn-rate alerting** (checking both a short window like 5m and a long window like 1h/6h, at different thresholds) exists specifically to avoid both false pages (short blip) and slow-boiling misses (small sustained leak that a short window wouldn't catch).

### Which check strategy should you actually use? (Decision rule)

| Situation | Use | Why |
|---|---|---|
| You just need "is the process/port alive" | Simple blackbox check (`curl -sf`, `systemctl is-active`) | Fast, zero dependencies, good enough for liveness probes |
| You need to alert on SLO burn / page a human correctly | Metrics-derived check against Prometheus/CloudWatch, with multi-window burn rate | Reflects real traffic, avoids both false pages and slow leaks that single-window blackbox checks miss |
| You need a Kubernetes liveness probe | Blackbox, cheap, local-only, no external dependency calls | Liveness probes must not depend on downstream services — a slow database must not make Kubernetes kill and restart a perfectly healthy pod |
| You need a Kubernetes readiness probe | Blackbox, but CAN check critical downstream dependencies | Readiness controls traffic routing, not process lifecycle — it's fine (even correct) to fail readiness if a DB connection pool isn't ready |

**Bottom line: liveness = "am I alive," cheap and local; readiness = "can I serve traffic right now," can check dependencies; SLO/paging decisions = derived from real traffic metrics with burn-rate math, not a single synthetic probe.** Confusing liveness with readiness (making liveness depend on a database) is one of the most common production-incident root causes in Kubernetes environments — a cascading restart storm triggered by a database blip.

## Hands-On Examples

**1. Basic blackbox SLI measurement — latency + status in one probe**
```bash
$ curl -o /dev/null -s -w "http_code=%{http_code} time_total=%{time_total}\n" https://api.internal/health
http_code=200 time_total=0.083421
```

**2. Wrapping that into an SLO-threshold health check with Nagios-style exit codes**
```bash
$ cat > slo_check.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
URL="https://api.internal/health"
LATENCY_WARN=0.300   # 300ms
LATENCY_CRIT=1.000   # 1s

result=$(curl -o /dev/null -s -w "%{http_code} %{time_total}" --max-time 2 "$URL") || {
    echo "UNKNOWN: curl itself failed (timeout/DNS/connection)"; exit 3;
}
read -r code latency <<< "$result"

if [[ "$code" != "200" ]]; then
    echo "CRITICAL: HTTP $code from $URL"; exit 2
elif (( $(echo "$latency > $LATENCY_CRIT" | bc -l) )); then
    echo "CRITICAL: latency ${latency}s exceeds ${LATENCY_CRIT}s SLO threshold"; exit 2
elif (( $(echo "$latency > $LATENCY_WARN" | bc -l) )); then
    echo "WARNING: latency ${latency}s above ${LATENCY_WARN}s target"; exit 1
else
    echo "OK: HTTP $code in ${latency}s"; exit 0
fi
EOF
$ chmod +x slo_check.sh
$ ./slo_check.sh; echo "exit=$?"
OK: HTTP 200 in 0.083421s
exit=0
```

**3. Computing a real availability SLI from access logs (metrics-derived, offline)**
```bash
$ awk '{print $9}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head
   48213 200
     902 404
     311 502
      44 500

$ total=$(wc -l < /var/log/nginx/access.log)
$ bad=$(awk '$9 ~ /^5/' /var/log/nginx/access.log | wc -l)
$ python3 -c "print(f'availability_sli = {100 - ($bad/$total*100):.4f}%')"
availability_sli = 99.2843%
```
99.28% is well under a 99.9% SLO — this single log-derived number is exactly what a burn-rate alert would be built on top of.

**4. Querying Prometheus directly for the SLI (metrics-derived, the production-grade version of #3)**
```bash
$ curl -s 'http://prometheus:9090/api/v1/query' \
    --data-urlencode 'query=sum(rate(http_requests_total{job="api",code=~"5.."}[5m])) / sum(rate(http_requests_total{job="api"}[5m]))' \
  | jq -r '.data.result[0].value[1]'
0.0071
```
0.71% error rate over the last 5 minutes — feed this straight into burn-rate math instead of re-deriving it from raw logs every time.

**5. Fast-burn alert logic — the "page someone now" case**
```bash
$ cat > burn_rate_check.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
# 99.9% SLO -> 0.1% error budget over 30d. Fast-burn: 14.4x over 1h window
# means the 30-day budget would be exhausted in ~2 days if sustained.
SLO_BUDGET=0.001
BURN_THRESHOLD=14.4

error_rate=$(curl -s 'http://prometheus:9090/api/v1/query' \
    --data-urlencode 'query=sum(rate(http_requests_total{code=~"5.."}[1h]))/sum(rate(http_requests_total[1h]))' \
    | jq -r '.data.result[0].value[1]')

burn_rate=$(python3 -c "print($error_rate / $SLO_BUDGET)")
echo "current 1h error rate: $error_rate, burn_rate: $burn_rate"

if (( $(echo "$burn_rate > $BURN_THRESHOLD" | bc -l) )); then
    echo "CRITICAL: fast burn detected (${burn_rate}x) — paging on-call"
    exit 2
fi
echo "OK: burn rate within tolerance"
EOF
$ ./burn_rate_check.sh
current 1h error rate: 0.021, burn_rate: 21.0
CRITICAL: fast burn detected (21.0x) — paging on-call
```

**6. Liveness vs readiness — two different scripts for two different jobs (Kubernetes probe pattern)**
```bash
$ cat > liveness.sh << 'EOF'
#!/bin/bash
# Cheap, local-only. Never checks the database — a slow DB must not kill this pod.
pgrep -f "myapp-server" > /dev/null || exit 1
exit 0
EOF

$ cat > readiness.sh << 'EOF'
#!/bin/bash
# Can and should check downstream dependencies — controls traffic routing, not lifecycle.
curl -sf --max-time 1 http://localhost:8080/internal/db-ping > /dev/null || exit 1
curl -sf --max-time 1 http://localhost:8080/internal/cache-ping > /dev/null || exit 1
exit 0
EOF
$ ./readiness.sh; echo "ready=$?"
ready=1
```
`ready=1` here correctly pulls this pod out of the load-balancer rotation without restarting it — exactly the intended behavior when only a downstream dependency is unhealthy.

**7. A cron-driven SLO-compliance report (turns per-request SLIs into a rollup a human reads)**
```bash
$ cat > slo_report.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
compliance=$(curl -s 'http://prometheus:9090/api/v1/query' \
    --data-urlencode 'query=1 - (sum(increase(http_requests_total{code=~"5.."}[28d])) / sum(increase(http_requests_total[28d])))' \
    | jq -r '.data.result[0].value[1]')
pct=$(python3 -c "print(f'{$compliance*100:.3f}')")
echo "28-day availability: ${pct}% (SLO target: 99.900%)"
(( $(echo "$compliance < 0.999" | bc -l) )) && echo "SLO BREACHED — error budget exhausted this window"
EOF
$ ./slo_report.sh
28-day availability: 99.874% (SLO target: 99.900%)
SLO BREACHED — error budget exhausted this window
```

## Practice Questions

1. Define SLI, SLO, and SLA in one sentence each, and explain why the SLA target is almost always looser than the internal SLO target.
2. What is an error budget, and how does it change the conversation from "is this down" to "should we halt feature releases and focus on reliability this sprint"?
3. Write a health-check script that returns 0/1/2/3 (OK/WARNING/CRITICAL/UNKNOWN) based on latency thresholds, and explain why "UNKNOWN" needs to be a distinct case from "CRITICAL."
4. What's the difference between a liveness probe and a readiness probe, and why should a liveness check almost never call a downstream database?
5. Explain "burn rate" in your own words, and why a single-window burn-rate alert (just "last 5 minutes") is worse than a multi-window approach.
6. You're asked to define an SLO for a new internal service with no historical data. How do you pick a starting number instead of guessing?
7. Given `sum(rate(http_requests_total{code=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))`, explain in plain English what this PromQL expression computes and why `rate()` is used instead of raw counters.
8. A health check script depends on `curl` reaching an external API that's occasionally slow but not down. How do you keep a slow-but-healthy dependency from making your check (and anything downstream of it) unreliable?
9. Your team's SLO is 99.9% over 30 days, and you've had a bad week that consumed 80% of the error budget. What decision does a senior engineer typically recommend at that point, and why?

## Interview Key Points

- **SLI is a measurement, SLO is a target, SLA is a target with a contractual penalty** — interviewers use this exact three-way distinction to check you're not using the terms interchangeably.
- **Error budget = 1 - SLO**, and its real value is as a *policy lever* (freeze releases, prioritize reliability work) — not just a number to report in a dashboard.
- **Liveness vs readiness is a classic trap**: liveness must be cheap/local and never depend on downstream services, or a struggling dependency turns into a self-inflicted restart storm across your whole fleet.
- **Burn rate over multiple windows** (fast + slow) is the production-grade version of alerting — know that a single fixed threshold either pages too much on blips or misses slow leaks, and multi-window multi-burn-rate solves both.
- **Blackbox synthetic checks vs metrics-derived checks** are different tools: synthetic is simple and dependency-free but only samples; metrics-derived reflects real user traffic but needs instrumentation to already exist. Know when to reach for which.
- A health check's own exit code should be as informative as the thing it's checking — a flat 0/1 loses the WARNING/UNKNOWN distinction that lets monitoring systems avoid over-paging.
- Being asked to "design an SLO" in an interview is really a design-thinking exercise: pick a meaningful SLI (usually availability or latency), anchor the target to real historical data or business need (not an arbitrary "five nines"), and state a measurement window — say all three explicitly.
- A script that itself becomes expensive or flaky (e.g., a health check that opens new connections without limits, or times out slowly) can become part of the incident it's supposed to detect — know to bound every check with `--max-time`/timeouts.
