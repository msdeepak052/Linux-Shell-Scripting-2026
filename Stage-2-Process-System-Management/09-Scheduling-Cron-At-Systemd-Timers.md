# Scheduling: `cron`, `at`, and systemd Timers

Three mechanisms cover Linux task scheduling — `cron` for recurring jobs, `at` for one-off future jobs, and systemd timers as the modern, more observable replacement for both. Knowing which to reach for (and why) is a common senior-level judgment question.

## Explanation

### `cron` and `crontab`

`cron` is a daemon (`crond`/`cron.service`) that reads crontabs and runs jobs at scheduled times, with minute-level granularity.

- **User crontabs**: `crontab -e` (edits `/var/spool/cron/crontabs/<user>`), `crontab -l` (list), `crontab -r` (remove all — dangerous, no confirmation). Runs as that user, no need to specify a user field.
- **System crontab**: `/etc/crontab` and files in `/etc/cron.d/` — these have an **extra user field** between the schedule and the command.
- **Convenience directories**: `/etc/cron.hourly/`, `/etc/cron.daily/`, `/etc/cron.weekly/`, `/etc/cron.monthly/` — drop an executable script in, no crontab syntax needed; run via `run-parts` on a schedule defined in `/etc/crontab` (typically driven by `anacron` on desktop/laptop systems so daily jobs still run if the machine was off).

**Cron syntax** (5 fields, left to right):
```
* * * * * command
│ │ │ │ │
│ │ │ │ └── day of week (0-7, both 0 and 7 = Sunday)
│ │ │ └──── month (1-12)
│ │ └────── day of month (1-31)
│ └──────── hour (0-23)
└────────── minute (0-59)
```
Special characters: `*` any value, `,` list (`1,15`), `-` range (`9-17`), `/` step (`*/5` = every 5 units). Shortcuts: `@reboot`, `@daily`, `@hourly`, `@weekly`, `@monthly`, `@yearly`.

**Cron gotchas:**
- Cron jobs run with a **minimal environment** (no login shell, sparse `$PATH`, no interactive profile sourced) — the #1 cause of "works when I run it manually, fails in cron." Always use absolute paths or explicitly set `PATH`/env vars at the top of the crontab.
- No built-in dependency handling, retries, resource limits, or centralized logging — output is mailed to the user (if mail is set up) or silently dropped unless redirected: `... >> /var/log/myjob.log 2>&1`.
- `crontab -e` uses the invoking user's timezone/`$EDITOR`; system time changes and DST can cause skipped/duplicate runs unless `CRON_TZ` is set explicitly.
- No easy way to see "did this run, when, exit code" without your own logging — this is a big reason systemd timers are preferred in modern infra.

### `at` — one-off future jobs

```bash
echo "systemctl restart myapp" | at 23:00
at now + 30 minutes
at teatime tomorrow      # yes, "teatime" (4pm) is real syntax
atq                      # list pending at jobs
atrm <job_id>            # cancel one
```
Runs once, not recurring. Requires `atd` daemon running. Good for "do this one thing later tonight," not for recurring maintenance.

### systemd timers — the modern replacement

A timer unit (`myjob.timer`) pairs with a service unit (`myjob.service`, `Type=oneshot`) of the same base name (or points at another via `Unit=`).

```ini
[Timer]
OnCalendar=*-*-* 02:30:00      # cron-like but more readable; also: OnCalendar=daily, weekly, etc.
OnBootSec=15min                 # relative to boot — monotonic timers
OnUnitActiveSec=1h              # relative to last activation — good for "every N since last run"
Persistent=true                 # if the system was OFF when it should've run, run it ASAP on boot (catch-up, like anacron)
RandomizedDelaySec=300          # spread load across a fleet, avoid thundering herd
AccuracySec=1min

[Install]
WantedBy=timers.target
```

**Why prefer timers over cron in production:**
| | cron | systemd timer |
|---|---|---|
| Logging | manual redirection needed | automatic via journald (`journalctl -u myjob.service`) |
| Dependency management | none | full systemd `[Unit]` deps (`After=`, `Requires=`) |
| Resource control | none | cgroups: `CPUQuota=`, `MemoryMax=`, etc. via the service unit |
| Missed-run catch-up | only via `anacron` add-on | built-in via `Persistent=true` |
| Run-status introspection | none easily | `systemctl status`, `systemctl list-timers` |
| Environment | minimal/sparse | inherits systemd service environment handling (`EnvironmentFile=`, etc.) |
| Jitter/fleet spread | none | `RandomizedDelaySec=` |
| Manual trigger for testing | run the exact command yourself | `systemctl start myjob.service` runs it exactly as scheduled would |

Cron is still fine for quick, simple, non-critical personal/dev-box jobs. For anything production-grade — especially where you need to know *if* and *how* it failed — systemd timers are the senior-engineer answer.

## Hands-On Examples

**1. Editing a user crontab**
```bash
$ crontab -e
# m h  dom mon dow   command
0 2 * * * /opt/scripts/backup.sh >> /var/log/backup.log 2>&1
*/15 * * * * /opt/scripts/healthcheck.sh
0 9 * * 1-5 /opt/scripts/weekday_report.sh

$ crontab -l
0 2 * * * /opt/scripts/backup.sh >> /var/log/backup.log 2>&1
*/15 * * * * /opt/scripts/healthcheck.sh
0 9 * * 1-5 /opt/scripts/weekday_report.sh
```

**2. System-wide crontab entry (`/etc/cron.d/`) — note the extra user field**
```bash
$ sudo tee /etc/cron.d/log-cleanup > /dev/null << 'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * root find /var/log/myapp -name "*.log" -mtime +14 -delete
EOF
```

**3. Debugging the classic "works manually, fails in cron" PATH issue**
```bash
$ crontab -l
* * * * * myscript.sh   # relies on PATH to find it — fragile

$ crontab -e
* * * * * /opt/scripts/myscript.sh   # absolute path — fixed

# Or capture cron's actual environment to compare against your shell:
* * * * * env > /tmp/cron-env.txt
$ diff <(env) /tmp/cron-env.txt
```

**4. One-off scheduled job with `at`**
```bash
$ echo "systemctl restart myapp" | at 23:30
job 7 at Sat Aug  8 23:30:00 2026

$ atq
7    Sat Aug  8 23:30:00 2026 a deepak

$ atrm 7
$ atq
```

**5. A systemd timer + service pair for a nightly backup**
```bash
$ sudo tee /etc/systemd/system/backup.service > /dev/null << 'EOF'
[Unit]
Description=Nightly backup job

[Service]
Type=oneshot
ExecStart=/opt/scripts/backup.sh
EOF

$ sudo tee /etc/systemd/system/backup.timer > /dev/null << 'EOF'
[Unit]
Description=Run backup.service nightly at 02:30

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true
RandomizedDelaySec=180

[Install]
WantedBy=timers.target
EOF

$ sudo systemctl daemon-reload
$ sudo systemctl enable --now backup.timer
```

**6. Inspecting scheduled timers and their last/next run**
```bash
$ systemctl list-timers --all
NEXT                         LEFT     LAST                          PASSED  UNIT           ACTIVATES
Sun 2026-08-09 02:30:00 UTC  16h left Sat 2026-08-08 02:30:04 UTC   7h ago  backup.timer   backup.service
Sat 2026-08-08 12:00:00 UTC  1h 45min Sat 2026-08-08 10:00:00 UTC   15min   report.timer   report.service
```

**7. Manually triggering a timer's service to test it (without waiting for the schedule)**
```bash
$ sudo systemctl start backup.service
$ journalctl -u backup.service -n 20 --no-pager
Aug 08 10:22:01 web01 systemd[1]: Starting Nightly backup job...
Aug 08 10:22:14 web01 backup.sh[20344]: Backup completed: /backups/app_20260808.tar.gz
Aug 08 10:22:14 web01 systemd[1]: backup.service: Deconstruct exited cleanly.
```

**8. `Persistent=true` catch-up behavior after downtime**
```bash
# Machine was powered off from 02:00-06:00, missing the 02:30 scheduled run
$ systemctl list-timers backup.timer
NEXT                         LEFT       LAST                          PASSED     UNIT
Sun 2026-08-09 02:30:00 UTC  20h left   Sat 2026-08-08 06:05:12 UTC   4h ago     backup.timer
# LAST shows 06:05 (right after boot), not the missed 02:30 — Persistent=true triggered a catch-up run
```

## Practice Questions

1. Write a cron entry that runs `/opt/scripts/sync.sh` every 15 minutes, only on weekdays, between 9 AM and 6 PM.
2. A cron job runs fine when you execute it manually but silently fails under cron. What are the top 2-3 causes, and how do you debug it systematically?
3. What's the difference between a user crontab (`crontab -e`) and an entry in `/etc/cron.d/`? What extra field does the latter require?
4. Explain the difference between `OnBootSec=`, `OnUnitActiveSec=`, and `OnCalendar=` in a systemd `[Timer]` section — give a scenario where each is the right choice.
5. Why would `Persistent=true` on a systemd timer matter for a laptop or a machine that's frequently rebooted? What happens without it?
6. You're designing a fleet-wide nightly job across 200 servers hitting a shared DB. What systemd timer directive prevents them all firing at exactly the same second, and why does that matter?
7. Compare cron and systemd timers on: logging/observability, resource limiting, and missed-run recovery. Which would you choose for a critical production backup job, and why?
8. How do you list all currently scheduled systemd timers along with their next and last run times?
9. Write a systemd timer that runs a service every day at 3:15 AM, and the paired oneshot service unit it targets.
10. How would you schedule a single one-time job to run tonight at 11 PM without creating a recurring cron entry or a systemd timer?

## Real Interview Questions (Company-Attributed)

- "What is a cronjob and how is it used?" — asked at *Deloitte, Infosys, Verizon*
- "Write a cron expression to schedule a job in Linux." — asked at *Oracle*
- "How would you schedule a task to run every 15 minutes, using cron on Linux (and PowerShell on Windows)?" — asked at *Wipro*
- "Explain the use of `at` and `atq`." — asked at *Sigmoid* (part of a rapid-fire "explain these Linux commands" interview round)

## Interview Key Points

- Cron's **minimal environment** (sparse `$PATH`, no profile sourcing) is the single most common real-world cron failure mode — always cite absolute paths / explicit `PATH=`/env as the fix.
- Know cron field order cold (`min hour dom month dow`) and that `/etc/cron.d` / `/etc/crontab` have an **extra user field** that a plain user crontab does not.
- systemd timers are the "correct modern answer" for production recurring jobs — cite journald logging, cgroup resource limits, `Persistent=true` catch-up, and `RandomizedDelaySec=` for fleet jitter as concrete advantages over cron.
- `at` is for **one-time** future jobs, not recurring — don't confuse it with cron in an answer.
- A timer unit needs a paired service unit (usually `Type=oneshot`) of the same base name unless `Unit=` overrides it — a common setup mistake is forgetting the `.service` file entirely.
- `Persistent=true` is the systemd-timer equivalent of `anacron`'s catch-up behavior for machines that aren't always on — good to name explicitly.
- You can always test a timer's underlying job on demand with `systemctl start <name>.service` — it runs exactly as the timer would trigger it, useful for validating before waiting on the schedule.
- Redirecting cron job output (`>> logfile 2>&1`) is not optional in production — without it, failures vanish into mail that's usually not configured, versus systemd timers where `journalctl -u` "just works."
