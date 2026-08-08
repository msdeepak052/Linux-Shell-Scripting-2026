# Cron & systemd-timer Integration

Reliable scheduling of automation scripts — and the real operational differences between the two mechanisms that determine which one you should reach for.

## Explanation

### How cron actually works

`cron` (the daemon `crond`) wakes up every minute, reads crontabs (`/etc/crontab`, `/etc/cron.d/*`, per-user via `crontab -e` stored under `/var/spool/cron/`), and forks/execs any job whose schedule matches the current minute. Each field: `minute hour day-of-month month day-of-week command`. Crucially:

- Jobs run in a **minimal environment** — no login shell, no `.bashrc`/`.profile` sourced, a stripped `PATH` (often just `/usr/bin:/bin`). The #1 cause of "works when I run it manually, fails under cron" is a missing `PATH` entry or unset environment variable your script assumed existed.
- **No built-in overlap protection** — if a job takes longer than its interval, cron happily starts a second instance on top of the first. You must add your own locking (`flock`).
- **No built-in logging** — stdout/stderr from a cron job either go to the user's local mail (`MAILTO` in crontab) or are silently discarded unless you redirect them yourself.
- **If the machine is off/asleep at the scheduled time, the job is simply skipped** — no catch-up, no memory that it was missed.
- Special strings: `@reboot`, `@daily`, `@hourly` etc. are shorthand cron accepts alongside the 5-field syntax.

### How systemd timers actually work

A systemd timer is **two files**: a `.timer` unit (defines *when*) paired with a `.service` unit of the same base name (defines *what* — the actual command, as a normal systemd service). This split is the biggest structural difference from cron, where schedule and command live in one line.

- **`OnCalendar=`** uses systemd's calendar expression syntax (`*-*-* 02:00:00`, `Mon..Fri 09:00`, `daily`, `weekly`) — more expressive than cron for things like "last day of the month" or "every 15 minutes but only on weekdays."
- **`OnBootSec=` / `OnUnitActiveSec=`** enable monotonic scheduling relative to boot time or since the timer last fired — cron has no equivalent.
- **`Persistent=true`** — if the machine was off when the timer should have fired, it fires once at next boot. This alone is a common reason ops teams migrate laptops/dev boxes/cloud instances with unpredictable uptime from cron to timers.
- **Logging is automatic** via journald — `journalctl -u myjob.service` gives you stdout/stderr/exit status with no redirection boilerplate.
- **Dependency and environment control** — the paired `.service` unit can declare `After=network-online.target`, resource limits (`MemoryMax=`, `CPUQuota=`), `User=`, and a full, explicit environment — no more "it broke because cron's PATH is different."
- **No accidental overlap** by default — systemd won't start a new run of a service that's still active from the last trigger (you'd need `AllowIsolate`-type tricks to force concurrent runs, whereas cron requires you to explicitly prevent them).

### Which one should you actually use? (Decision rule)

| Situation | Use | Why |
|---|---|---|
| Simple, always-on server, quick one-off scheduled task, team already has crontabs everywhere | **cron** | Zero setup ceremony — one line in a crontab. Still completely valid for simple cases. |
| Job's success/failure needs to be observable via `systemctl status` / `journalctl`, or needs resource limits, or needs to run on a laptop/cloud instance that isn't always on | **systemd timer** | Structured logging, `Persistent=true` catch-up, resource controls, dependency ordering — all first-class. |
| Complex calendar logic ("first Monday of month," "every 15 min on weekdays only") | **systemd timer** | `OnCalendar=` expressions handle this natively; cron needs ugly workarounds or extra tooling. |
| You need the job to overlap-protect itself and you don't want to hand-write `flock` boilerplate | **systemd timer** | Built-in — a still-running service instance blocks the next trigger by default. |
| Minimal container / embedded / no systemd present | **cron** | systemd isn't always available; cron (or a cron-like tool) is often the only option. |

**Bottom line**: for anything running on a modern systemd-based server that needs to be *trusted* in production (must run even after downtime, must log cleanly, must not silently double-run) — use a systemd timer. Reach for cron only for quick, low-stakes scheduling, environments without systemd, or when a team's existing tooling already centers on crontabs.

### The PATH/environment trap (both mechanisms, but especially cron)

Because scheduled jobs don't source your shell profile, always use **absolute paths** to binaries and scripts, and set `PATH` explicitly at the top of the crontab (or explicitly in `Environment=`/`EnvironmentFile=` for systemd) rather than assuming interactive-shell defaults.

## Hands-On Examples

> Interactive multi-line blocks below print bash's `>` continuation prompt automatically — it's not something you type.

**1. A crontab entry — and the classic "worked manually, fails under cron" bug**
```bash
$ crontab -l
0 2 * * * /usr/local/bin/backup-app.sh

$ # Manually it works because your shell's PATH includes /usr/local/bin AND aws-cli's location:
$ which aws
/usr/local/bin/aws

$ # But under cron, PATH is minimal — the script's `aws s3 cp` line fails silently:
$ crontab -l
PATH=/usr/bin:/bin
0 2 * * * /usr/local/bin/backup-app.sh >> /var/log/backup-app.log 2>&1
$ tail -3 /var/log/backup-app.log
./backup-app.sh: line 12: aws: command not found
```
Fix: either set `PATH=/usr/local/bin:/usr/bin:/bin` at the top of the crontab, or (better) use absolute paths for every external command inside the script itself.

**2. Locking a cron job against overlap with `flock`**
```bash
$ crontab -l
*/5 * * * * /usr/bin/flock -n /var/run/sync-job.lock /usr/local/bin/sync-job.sh
```
`flock -n` (non-blocking) means: if the lock is already held by a previous still-running instance, this invocation exits immediately instead of queueing or running concurrently.

**3. A minimal systemd timer + service pair**
```bash
$ cat /etc/systemd/system/db-backup.service
[Unit]
Description=Nightly database backup

[Service]
Type=oneshot
User=backupuser
ExecStart=/usr/local/bin/backup-app.sh
```
```bash
$ cat /etc/systemd/system/db-backup.timer
[Unit]
Description=Run db-backup.service nightly at 02:00

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```
```bash
$ systemctl daemon-reload
$ systemctl enable --now db-backup.timer
Created symlink /etc/systemd/system/timers.target.wants/db-backup.timer → /etc/systemd/system/db-backup.timer.
```

**4. `Persistent=true` catching a missed run — the feature cron simply doesn't have**
```bash
$ # Laptop/VM was suspended from 01:00-09:00, missing the 02:00 scheduled run
$ systemctl list-timers db-backup.timer
NEXT                        LEFT       LAST                         PASSED       UNIT             ACTIVATES
Mon 2026-08-10 02:00:00 UTC 16h left   n/a                          n/a          db-backup.timer  db-backup.service

$ # After boot at 09:03, Persistent=true fires the missed job almost immediately:
$ journalctl -u db-backup.service --since "09:00" | tail -3
Aug 08 09:03:14 host systemd[1]: Starting Nightly database backup...
Aug 08 09:03:19 host systemd[1]: db-backup.service: Deactivated successfully.
Aug 08 09:03:19 host systemd[1]: Finished Nightly database backup.
```

**5. Inspecting timer schedule and status**
```bash
$ systemctl list-timers --all
NEXT                        LEFT       LAST                         PASSED       UNIT                  ACTIVATES
Sun 2026-08-09 02:00:00 UTC 17h left   Sat 2026-08-08 02:00:00 UTC  7h ago       db-backup.timer       db-backup.service
Sun 2026-08-09 03:15:00 UTC 18h left   n/a                          n/a          log-cleanup.timer     log-cleanup.service

$ systemctl status db-backup.timer
● db-backup.timer - Run db-backup.service nightly at 02:00
     Loaded: loaded (/etc/systemd/system/db-backup.timer; enabled)
     Active: active (waiting) since Fri 2026-08-08 08:00:00 UTC; 3h ago
    Trigger: Sun 2026-08-09 02:00:00 UTC; 17h left
```

**6. Overlap protection built into systemd — proof it just works**
```bash
$ systemctl start db-backup.service &
$ systemctl start db-backup.service
$ systemctl status db-backup.service | grep Active
   Active: active (running) since Sat 2026-08-08 12:01:03 UTC; 4s ago
$ # second `systemctl start` is a no-op while the unit is still active — no duplicate process spawned
```

**7. Debugging a cron job that "isn't running" — checking the right logs**
```bash
$ grep CRON /var/log/syslog | tail -5
Aug  8 02:00:01 host CRON[19234]: (backupuser) CMD (/usr/local/bin/backup-app.sh)
Aug  8 02:00:03 host CRON[19233]: (CRON) info (No MTA installed, discarding output)

$ # "No MTA installed, discarding output" — output silently dropped because MAILTO has nowhere to go
$ crontab -l
MAILTO=""
0 2 * * * /usr/local/bin/backup-app.sh >> /var/log/backup-app.log 2>&1
$ # Fix: always redirect explicitly rather than relying on cron's mail delivery
```

**8. Calendar expression systemd can do that plain cron can't express cleanly**
```bash
$ systemd-analyze calendar "Mon..Fri 09,17:00:00"
  Original form: Mon..Fri 09,17:00:00
Normalized form: Mon..Fri 09,17:00:00
    Next elapse: Mon 2026-08-10 09:00:00 UTC
       (in UTC): Mon 2026-08-10 09:00:00 UTC
       From now: 1 day 20h left
```
"Twice a day, weekdays only, at 09:00 and 17:00" — expressible in one `OnCalendar=` line; the cron equivalent (`0 9,17 * * 1-5`) is doable too here, but once you need "last day of month" or "every 2 hours starting 3 hours after boot," cron has no native syntax at all.

## Practice Questions

1. A script runs fine when you execute it manually but fails under cron with `command not found`. What's the most likely cause, and what are the two ways to fix it?
2. Why doesn't cron have built-in overlap protection, and what's the standard fix for a job that might occasionally run longer than its schedule interval?
3. Explain `Persistent=true` on a systemd timer. Describe a real scenario (e.g., a laptop or a cloud instance that gets stopped overnight) where this matters and cron would silently fail to compensate.
4. Walk through the two files needed for a systemd timer and explain why the schedule and the executed command are split into separate units instead of one file.
5. What does `flock -n /var/run/job.lock command` do inside a crontab entry, and why is `-n` (non-blocking) usually the right choice over blocking `flock`?
6. Where does a systemd service's stdout/stderr go by default, and how do you view it? Contrast this with where cron job output goes if you don't redirect it.
7. Write a systemd `OnCalendar=` expression for "every 15 minutes, only during business hours (9am-5pm), Monday through Friday," and explain why this is awkward to express in raw 5-field cron syntax.
8. A teammate says "just use cron, it's simpler." Give two concrete production scenarios where a systemd timer's behavior would have prevented an incident that cron's would not.
9. What is `RandomizedDelaySec=` for on a systemd timer, and why might you want it on a job that runs across many hosts simultaneously?
10. Explain why absolute paths (or an explicitly-set `PATH`) matter so much for cron jobs specifically, tying it back to what environment a cron job actually inherits versus an interactive shell.

## Interview Key Points

- **The PATH/environment trap is the single most common real-world cron bug** — "works manually, fails under cron" is close to a guaranteed interview scenario question; the answer is always "cron jobs don't source shell profiles, so PATH and other env vars are minimal — use absolute paths or set PATH explicitly."
- **Persistent=true is systemd's standout feature over cron** — know this cold as the concrete, memorable differentiator: missed runs (machine off/asleep) get caught up at next boot with systemd timers; cron just skips them with no memory of the miss.
- **Built-in overlap protection**: systemd won't re-trigger a service that's still active; cron will happily stack duplicate runs unless you add `flock` yourself — a strong "which one prevents this class of bug by default" talking point.
- **Logging**: systemd timers get automatic, structured logs via `journalctl -u <service>`; cron requires manual redirection (`>> file 2>&1`) or relies on local mail delivery, which is frequently misconfigured/unavailable ("No MTA installed, discarding output" is a real, common gotcha).
- Know that a systemd timer is **two coupled unit files** (`.timer` + `.service`) — this split is what enables resource limits, dependency ordering (`After=network-online.target`), and a distinct execution user, none of which cron has any concept of.
- `OnCalendar=` expressions are strictly more expressive than 5-field cron syntax for complex schedules — be ready to write one (`systemd-analyze calendar "..."` is the tool to validate/preview them) and explain why "every 15 min on weekdays 9-5" is clean in systemd but ugly in cron.
- Don't over-correct: cron is still perfectly valid and lower-ceremony for simple, low-stakes, always-on-server scheduling — the senior answer is a decision rule based on the job's criticality/environment, not "always use systemd timers, cron is dead."
