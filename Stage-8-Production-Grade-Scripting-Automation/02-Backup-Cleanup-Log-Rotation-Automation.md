# Backup, Cleanup & Log-Rotation Automation

Scripted, scheduled data protection and disk-hygiene — the unglamorous automation that keeps production hosts from silently filling their disks or losing data with no recovery path.

## Explanation

### Backup scripting: the parts people forget

A backup script that "just runs `tar`" is not production-grade. The pieces that separate a toy script from something a senior engineer would trust:

- **Locking** — prevent two overlapping runs (a slow backup + a cron firing again) from corrupting output or doubling load. `flock` is the standard tool for this.
- **Consistency** — for databases, a filesystem-level copy of open files can capture a torn write. Use the tool's native dump (`pg_dump`, `mysqldump`, `mongodump`) or a consistent snapshot (LVM/filesystem snapshot) instead of `tar`-ing live data files.
- **Verification** — a backup you've never restored is a hope, not a backup. At minimum, verify the archive isn't corrupt (`tar -tzf` / `gzip -t`); ideally, periodically test-restore.
- **Retention** — old backups must be pruned on a schedule (see cleanup below) or disk fills and the *next* backup fails.
- **Off-host copy** — a backup that lives only on the same disk as the data protects against nothing (accidental `rm -rf`, yes; disk failure, no). Ship it to S3/GCS/another host.
- **Exit-code discipline** — cron/systemd needs to know if the backup actually succeeded; swallowing errors silently is how you discover backups have been failing for six months.

### Cleanup automation: `find` is the core tool

Most disk-hygiene automation boils down to: find files matching a pattern/age, then act (delete/compress/move). The workhorse:

```bash
find /path -type f -mtime +N -name "pattern" -delete
```

Key `find` time predicates:
- `-mtime +N` — modified more than N days ago (based on `mtime`, file content change)
- `-atime +N` — accessed more than N days ago (less reliable — many mounts use `noatime` for performance, which breaks this)
- `-ctime +N` — inode/metadata changed more than N days ago (permissions, ownership — NOT "created time", Linux doesn't track true creation time)
- `-mmin +N` — same as `-mtime` but in minutes, for finer-grained cleanup windows

**Danger zone**: `find ... -delete` (or `-exec rm {} \;`) is unforgiving — always dry-run first with `-print` before swapping in `-delete`, and always scope the path tightly (never run a cleanup `find` from `/`).

### Log rotation: `logrotate` vs. hand-rolled

`logrotate` is the standard Linux tool (config-driven, runs from cron/systemd timer as `logrotate.timer` on modern distros) — it handles rotation, compression, retention count, and can signal a service to reopen its log file (`postrotate`/`sharedscripts`). Config lives per-app in `/etc/logrotate.d/`.

Hand-rolled log rotation (a bash script that does `mv app.log app.log.1; gzip app.log.1; find -mtime +30 -delete`) is what you write only when: the app can't be told to reopen its log file cleanly, you need custom logic `logrotate` doesn't support, or you're rotating something that isn't a traditional syslog-style file (e.g., a directory of per-run job logs, cleaned by age rather than "rotate on size/day").

### Which one should you actually use? (Decision rule)

| Situation | Use |
|---|---|
| Standard application log file (nginx, app stdout redirected to a file) | **`logrotate`** — battle-tested, handles signal-to-reopen, compression, retention in one declarative config |
| Rotating a directory of many small per-job/per-run files by age, not by "one growing file" | Hand-rolled `find -mtime +N -delete` (or move-then-compress) script — `logrotate` isn't built for this shape |
| Backups, temp file cleanup, old build artifacts | Hand-rolled cleanup script — `logrotate` is specifically for log files, not general disk hygiene |
| You need custom retention logic (e.g., "keep 1 backup per day for 7 days, then 1 per week for a month") | Hand-rolled script with tiered `find`/date-bucketing logic — this exceeds what config-driven `logrotate` naturally expresses |

**Bottom line**: reach for `logrotate` first for anything that's genuinely a growing log file — it already solved the hard parts (safe rotation without losing writes, compression, signaling). Write your own `find`-based cleanup logic for everything else (backups, artifacts, per-job output directories, tiered retention).

## Hands-On Examples

> The heredocs below (`cat > file << 'EOF' ... EOF`) write scripts/configs to disk without you needing to type `>` continuation prompts manually — bash still shows `>` while the heredoc body is open, since it's waiting for the terminating `EOF`.

**1. Locked, verified backup script with off-host copy**
```bash
$ cat > /usr/local/bin/backup-app.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOCKFILE="/var/run/backup-app.lock"
BACKUP_DIR="/backups"
DATE=$(date +%Y%m%d-%H%M%S)
ARCHIVE="$BACKUP_DIR/app-$DATE.tar.gz"

exec 200>"$LOCKFILE"
flock -n 200 || { echo "Backup already running, exiting"; exit 1; }

tar -czf "$ARCHIVE" -C /opt/app data/ config/
tar -tzf "$ARCHIVE" > /dev/null || { echo "ERROR: archive verification failed"; exit 1; }

aws s3 cp "$ARCHIVE" "s3://company-backups/app/$(basename "$ARCHIVE")" \
    || { echo "ERROR: off-host upload failed"; exit 1; }

echo "Backup completed and verified: $ARCHIVE"
EOF
$ chmod +x /usr/local/bin/backup-app.sh
$ ./backup-app.sh
Backup completed and verified: /backups/app-20260808-020001.tar.gz
```

**2. `flock` preventing overlapping runs — proof**
```bash
$ ./backup-app.sh &
[1] 30122
$ ./backup-app.sh
Backup already running, exiting
$ echo $?
1
```

**3. Consistent database dump instead of a raw file copy**
```bash
$ pg_dump -U postgres -Fc mydb > /backups/mydb-$(date +%Y%m%d).dump
$ echo "exit: $?"
exit: 0

$ # Verify a pg_dump custom-format archive without a full restore
$ pg_restore --list /backups/mydb-20260808.dump | head -3
;
; Archive created at 2026-08-08 02:00:14 UTC
;     dbname: mydb
```

**4. Cleanup: dry-run before delete (the correct order of operations)**
```bash
$ find /var/tmp/build-artifacts -type f -mtime +7 -print
/var/tmp/build-artifacts/app-1.2.0.tar.gz
/var/tmp/build-artifacts/app-1.2.1.tar.gz
/var/tmp/build-artifacts/debug-2026-07-28.log

$ # Only after confirming the -print list is exactly what you expect:
$ find /var/tmp/build-artifacts -type f -mtime +7 -delete
$ find /var/tmp/build-artifacts -type f -mtime +7 -print
$ # (empty — confirms cleanup worked)
```

**5. Backup retention: keep last N archives, delete the rest**
```bash
$ ls -1t /backups/app-*.tar.gz
/backups/app-20260808-020001.tar.gz
/backups/app-20260807-020001.tar.gz
/backups/app-20260806-020001.tar.gz
/backups/app-20260805-020001.tar.gz
/backups/app-20260804-020001.tar.gz
/backups/app-20260803-020001.tar.gz
/backups/app-20260802-020001.tar.gz
/backups/app-20260801-020001.tar.gz

$ # Keep the newest 7, delete anything older
$ ls -1t /backups/app-*.tar.gz | tail -n +8 | xargs -r rm -v
removed '/backups/app-20260801-020001.tar.gz'
```

**6. `logrotate` config for an app that logs to a plain file**
```bash
$ cat > /etc/logrotate.d/myapp << 'EOF'
/var/log/myapp/app.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 myapp myapp
    postrotate
        systemctl reload myapp >/dev/null 2>&1 || true
    endscript
}
EOF
$ logrotate -d /etc/logrotate.d/myapp   # -d = debug/dry-run, shows what WOULD happen
reading config file /etc/logrotate.d/myapp
Handling 1 logs

rotating pattern: /var/log/myapp/app.log  after 1 days (14 rotations)
empty log files are not rotated, old logs are removed
considering log /var/log/myapp/app.log
  log needs rotating
rotating log /var/log/myapp/app.log, log->rotateCount is 14
dateext suffix '-20260808'
glob pattern '-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
renaming /var/log/myapp/app.log to /var/log/myapp/app.log-20260808
running postrotate script
```

**7. Hand-rolled rotation for a directory of per-job logs (not a fit for `logrotate`)**
```bash
$ cat > /usr/local/bin/cleanup-job-logs.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG_DIR="/var/log/batch-jobs"

# Compress anything older than 1 day, not already compressed
find "$LOG_DIR" -type f -name "*.log" -mtime +1 ! -name "*.gz" -exec gzip {} \;

# Delete compressed logs older than 30 days
find "$LOG_DIR" -type f -name "*.log.gz" -mtime +30 -delete

echo "Job log cleanup complete: $(find "$LOG_DIR" -type f | wc -l) files remain"
EOF
$ chmod +x /usr/local/bin/cleanup-job-logs.sh
$ ./cleanup-job-logs.sh
Job log cleanup complete: 214 files remain
```

**8. Incident-flavored example: emergency disk-space recovery via cleanup script**
```bash
$ df -h /var
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p3   50G   49G   512M  99% /var

$ du -sh /var/log/* 2>/dev/null | sort -rh | head -5
32G     /var/log/myapp
8.1G    /var/log/journal
2.3G    /var/log/audit
1.1G    /var/log/nginx
0.4G    /var/log/other

$ find /var/log/myapp -name "*.log.*" -mtime +3 -delete
$ journalctl --vacuum-size=500M
Vacuuming done, freed 7.6G of archived journals from /var/log/journal.

$ df -h /var
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p3   50G   30G   19G   62% /var
```

## Practice Questions

1. Why is `flock` necessary in a backup script even when it's only triggered by a single cron entry? Describe a real scenario where overlapping runs could happen anyway.
2. What's wrong with `tar`-ing a live PostgreSQL data directory as a "backup," and what should you do instead?
3. Write a `find` command that deletes files older than 30 days in `/tmp/uploads`, and explain why you should run it with `-print` first before adding `-delete`.
4. Explain the difference between `-mtime`, `-atime`, and `-ctime` in `find`. Why is `-atime` often unreliable for cleanup scripts on modern systems?
5. You're asked "would you use `logrotate` or write your own script?" for rotating a directory containing thousands of individual per-request debug log files. What's your answer and why?
6. Write a one-liner that keeps only the 7 most recent backup archives in a directory (by mtime) and deletes the rest.
7. A `logrotate` config uses `postrotate ... systemctl reload myapp ... endscript`. What problem does this solve, and what would break without it?
8. What does `logrotate -d` do, and why would you always run it before deploying a new logrotate config to production?
9. A junior engineer's backup script has no verification step and no off-host copy. Walk through what could go wrong and how you'd fix both gaps.
10. Disk usage on `/var` hits 99%. Walk through the diagnostic and remediation commands you'd run to reclaim space safely without deleting something you shouldn't (include `du`, `find`, and `journalctl --vacuum-size`).

## Real Interview Questions (Company-Attributed)

- "Write a shell script to find and delete all files in a directory older than 30 days." — asked at *an unnamed company (via community-sourced interview notes)*
- "Write a script to delete files older than 10 days." — asked at *IBM*
- "Write a shell script to delete log files older than 30 days." — asked at *Sigmoid*
- "Write a shell script to back up logs from the last 7 days and remove older ones." — asked at *Qentelli Solutions*
- "Write a shell script that compresses logs older than 30 days and deletes logs older than 90 days, scheduled daily via cron." — asked at *an unnamed company (via community-sourced interview notes)*
- "Can we create AWS backups using shell scripting?" — asked at *Deloitte*

## Interview Key Points

- **A backup without verification and without an off-host copy is not a backup** — this is the single most common gap interviewers probe for; always mention `tar -tzf`/restore testing and shipping to S3/another host, not just "run tar on a cron job."
- **`flock` for exclusivity** is a strong senior signal — most junior scripts assume "cron only fires once," which breaks the moment a job runs long or gets manually triggered while the scheduled one is still going.
- Know the **`logrotate` vs. hand-rolled** decision rule cold: `logrotate` for standard growing log files (it handles the signal-to-reopen problem correctly via `postrotate`), hand-rolled `find`-based scripts for backups, artifacts, and non-log cleanup.
- **`-mtime` vs `-atime` vs `-ctime`** is a recurring trap question — know that Linux has no true "creation time" in traditional filesystems (ctime is metadata-change time, not creation), and that `noatime` mount options (common for performance) make `-atime`-based cleanup unreliable.
- Always dry-run destructive `find ... -delete` commands with `-print` first, and scope paths tightly — this reflects real operational caution, and interviewers specifically listen for whether you mention it unprompted.
- For databases, know that a **native dump/snapshot beats a raw file copy** — `tar`-ing live data files risks capturing a torn/inconsistent write mid-transaction; `pg_dump`/`mysqldump`/LVM snapshots capture a consistent point-in-time state.
- `journalctl --vacuum-size=` / `--vacuum-time=` is the systemd-native way to reclaim space from journal logs specifically — worth knowing as a fast, safe first move in a disk-full incident before deleting application logs.
