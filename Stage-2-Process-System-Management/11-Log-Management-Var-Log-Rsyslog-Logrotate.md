# Log Management: `/var/log`, `rsyslog`, `logrotate`

Beyond the systemd journal, traditional flat-file logging under `/var/log` — fed by `rsyslog` and kept under control by `logrotate` — is still the backbone of most production Linux logging, especially for anything not managed purely by systemd.

## Explanation

### `/var/log` layout

| Path | Contents |
|---|---|
| `/var/log/syslog` (Debian) or `/var/log/messages` (RHEL) | General system log — catch-all for most facilities |
| `/var/log/auth.log` (Debian) or `/var/log/secure` (RHEL) | Authentication/authorization events — SSH logins, `sudo` usage |
| `/var/log/kern.log` | Kernel messages |
| `/var/log/dmesg` | Boot-time kernel ring buffer snapshot |
| `/var/log/boot.log` | Boot sequence output |
| `/var/log/cron` | Cron job execution log (RHEL; Debian logs cron to syslog) |
| `/var/log/wtmp`, `/var/log/btmp` | Binary login records — read via `last`/`lastb`, not directly readable |
| `/var/log/apt/` or `/var/log/dnf.log`/`/var/log/yum.log` | Package manager history |
| `/var/log/<app>/` | Per-application logs (nginx, postgresql, etc.) — most well-behaved apps get their own subdirectory |
| `/var/log/journal/` | The binary systemd journal (if persistent storage is enabled) |

### `rsyslog` — the traditional syslog daemon

Receives log messages tagged with a **facility** (source category: `auth`, `cron`, `daemon`, `kern`, `local0-7`, `mail`, `syslog`, `user`, etc.) and a **severity** (same 8 levels as journald: emerg/alert/crit/err/warning/notice/info/debug), and routes them based on rules.

- Config: `/etc/rsyslog.conf` plus drop-ins in `/etc/rsyslog.d/*.conf`.
- Rule syntax: `facility.severity   destination`
  ```
  auth,authpriv.*                /var/log/auth.log
  mail.*                         -/var/log/mail.log      # leading '-' = async/buffered write (perf)
  *.emerg                        :omusrmsg:*              # wall message to all logged-in users
  local0.*                       @@logserver.internal:514  # forward to remote syslog server (TCP, @@ = TCP, @ = UDP)
  ```
  Severity of `.severity` also means "this level and above" (same convention as journalctl `-p`). Use `.=severity` to match an exact level only.
- **Remote/centralized logging**: rsyslog can act as both client (forward logs off-box, `@@host:port`) and server (`ModLoad imtcp`/`imudp` + `input()` to receive from other hosts) — foundational for centralized logging before ELK/Splunk/etc. ingestion, and for compliance (logs surviving a compromised host).
- **journald relationship**: on modern systemd distros, journald usually collects everything first; rsyslog either reads from the journal (`imjournal` module) or receives forwarded messages from journald (`ForwardToSyslog=yes` in `journald.conf`) and then writes the classic flat files. So `/var/log/syslog` and `journalctl` often show overlapping content sourced differently.

### `logrotate` — preventing logs from filling the disk

Runs periodically (traditionally via cron, `/etc/cron.daily/logrotate`, or a `logrotate.timer` on modern systemd distros) reading `/etc/logrotate.conf` plus per-app configs in `/etc/logrotate.d/`.

Typical config:
```
/var/log/myapp/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 myapp myapp
    sharedscripts
    postrotate
        systemctl reload myapp > /dev/null 2>&1 || true
    endscript
}
```

Key directives:
- `daily`/`weekly`/`monthly` — rotation frequency.
- `rotate N` — keep N old rotated copies before deleting the oldest.
- `size 100M` — rotate when a log exceeds this size, regardless of schedule (can combine with time-based via `maxsize`).
- `compress` / `delaycompress` — gzip old logs; `delaycompress` skips compressing the most-recently-rotated file (so a process still writing briefly during rotation doesn't get a compressed file out from under it).
- `copytruncate` vs default (`create`) rotation method — **critical distinction**:
  - Default: renames the log file (`app.log` → `app.log.1`) then signals/HUPs the app to reopen a fresh file descriptor. Requires the app to support re-opening logs (most do, via `postrotate` sending `SIGHUP` or a reload).
  - `copytruncate`: copies the current content out, then truncates the original file **in place** — necessary for apps that keep a log file descriptor open and never reopen it, but has a small race-condition window where log lines written between the copy and the truncate are lost.
- `missingok` — don't error if the log file doesn't exist.
- `notifempty` — don't rotate an empty file.
- `create MODE OWNER GROUP` — create a new empty file with these permissions after rotation.
- `postrotate ... endscript` — run a command after rotation (commonly reload/HUP the app so it starts writing to the new file). `sharedscripts` runs it once for the whole glob instead of once per matched file.
- Test/debug: `logrotate -d /etc/logrotate.d/myapp` (dry run, verbose), `logrotate -f /etc/logrotate.d/myapp` (force rotation now).
- State tracked in `/var/lib/logrotate/status` (or `/var/lib/logrotate.status`) — records last rotation time per log, so it survives across cron/timer runs.

## Hands-On Examples

**1. Tailing and grepping classic flat-file logs**
```bash
$ tail -f /var/log/syslog
Aug 08 10:30:01 web01 CRON[21044]: (root) CMD (run-parts /etc/cron.hourly)
Aug 08 10:31:12 web01 myapp[19011]: WARN slow db query: 900ms

$ grep "Failed password" /var/log/auth.log | tail -5
Aug 08 03:12:04 web01 sshd[8821]: Failed password for invalid user admin from 203.0.113.44 port 51022 ssh2
Aug 08 03:12:07 web01 sshd[8821]: Failed password for invalid user admin from 203.0.113.44 port 51022 ssh2
```

**2. rsyslog rule: route app-specific facility to its own file**
```bash
$ sudo tee /etc/rsyslog.d/30-myapp.conf > /dev/null << 'EOF'
local0.*    /var/log/myapp/app.log
& stop
EOF
$ sudo systemctl restart rsyslog
# app configured to log via syslog(local0, ...) now writes to its own file, "& stop" prevents duplicate entry in syslog
```

**3. Forwarding logs to a central log server**
```bash
$ sudo tee -a /etc/rsyslog.conf > /dev/null << 'EOF'
*.* @@logserver.internal:514
EOF
$ sudo systemctl restart rsyslog
$ sudo systemctl status rsyslog --no-pager | head -5
```

**4. Setting up logrotate for a custom app**
```bash
$ sudo tee /etc/logrotate.d/myapp > /dev/null << 'EOF'
/var/log/myapp/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 myapp myapp
    sharedscripts
    postrotate
        systemctl kill -s HUP myapp.service
    endscript
}
EOF

$ sudo logrotate -d /etc/logrotate.d/myapp
reading config file /etc/logrotate.d/myapp
Handling 1 logs

rotating pattern: /var/log/myapp/*.log  after 1 days (14 rotations)
empty log files are not rotated, old logs are removed
considering log /var/log/myapp/app.log
  log needs rotating
```

**5. Forcing an immediate rotation (e.g., disk filling up right now)**
```bash
$ df -h /var
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1        50G   47G  1.2G  96% /var

$ du -sh /var/log/myapp/*.log
2.1G    /var/log/myapp/app.log

$ sudo logrotate -f /etc/logrotate.d/myapp
$ ls -lh /var/log/myapp/
-rw-r----- 1 myapp myapp    0 Aug  8 10:45 app.log
-rw-r----- 1 myapp myapp 2.1G Aug  8 10:45 app.log.1
$ sudo gzip /var/log/myapp/app.log.1     # or wait for next rotation to compress it
```

**6. `copytruncate` for an app that never reopens its log file**
```bash
$ sudo tee /etc/logrotate.d/legacyapp > /dev/null << 'EOF'
/var/log/legacyapp/output.log {
    weekly
    rotate 4
    copytruncate
    compress
}
EOF
# legacyapp keeps writing to the same inode via an fd it opened at startup and never releases —
# copytruncate avoids needing to restart it, at the cost of a tiny race window during truncate
```

**7. Checking logrotate's rotation state / debugging why a log wasn't rotated**
```bash
$ grep myapp /var/lib/logrotate/status
"/var/log/myapp/app.log" 2026-8-7-2:15:2

$ sudo logrotate -v -f /etc/logrotate.d/myapp 2>&1 | tail -15
rotating log /var/log/myapp/app.log, log->rotateCount is 14
dateext suffix '-20260808'
glob pattern '-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
renaming /var/log/myapp/app.log to /var/log/myapp/app.log-20260808
running postrotate script
```

**8. Confirming what actually invokes logrotate on this system**
```bash
$ systemctl list-timers | grep logrotate
Sat 2026-08-09 00:00:00 UTC  13h left  Sat 2026-08-08 00:00:12 UTC  10h ago  logrotate.timer  logrotate.service

$ cat /etc/cron.daily/logrotate 2>/dev/null
# on older/non-timer distros this exists instead; on this box it's the systemd timer that's active
```

## Practice Questions

1. `/var` is at 96% disk usage and one app's log file is 2GB. Walk through diagnosing this and forcing an immediate safe rotation.
2. Explain the difference between the default rotation method (rename + signal) and `copytruncate` in logrotate. When is `copytruncate` necessary, and what's its known downside?
3. A log file keeps growing even after logrotate ran and renamed it — the old (renamed) file is what's growing, not a new one. What's the most likely cause?
4. What's the difference between `rsyslog`'s `.severity` and `.=severity` in a rule's facility.severity selector?
5. How would you configure a host to forward all logs to a central log server, and what's the difference between `@host` and `@@host` in rsyslog syntax?
6. Explain `delaycompress` — why would you not want the most recently rotated log compressed immediately?
7. You add a new `/etc/logrotate.d/myapp` config. How do you test it without waiting for the next scheduled run, both in dry-run and forced modes?
8. What's the relationship between journald and rsyslog on a modern systemd-based distro — does one replace the other, or do they coexist, and how?
9. Where does logrotate track what it has already rotated and when, and why does that matter across repeated cron/timer runs?
10. A `postrotate` script needs to tell a running daemon to reopen its log file after rotation, but the daemon isn't a systemd service (no unit to `kill -s HUP` via systemctl). How else would you send that signal from within the `postrotate` block?

## Real Interview Questions (Company-Attributed)

- "What is a logrotate job and how does it work?" — asked at *Infosys*

## Interview Key Points

- Know the standard `/var/log` filenames and what's in each (`auth.log`/`secure`, `syslog`/`messages`, `kern.log`) — differs by distro family (Debian vs RHEL naming), and interviewers often probe whether you know both.
- **`copytruncate` vs default rotation** is a classic logrotate deep-dive question: default requires the app to reopen its FD (via signal/reload), `copytruncate` truncates in place for apps that can't — with a real (if small) risk of losing log lines written during the copy/truncate gap.
- `delaycompress` exists specifically to avoid compressing a file the application might still have a stale/buffered write in flight to — know the "why," not just the flag name.
- Understand the **journald <-> rsyslog relationship**: they coexist on most modern distros (`ForwardToSyslog=`, `imjournal`), not a strict either/or — a nuanced point that distinguishes senior answers.
- `rsyslog`'s facility.severity model (with `*` wildcards, `.=` exact match, `-` for async buffered writes, `@`/`@@` for UDP/TCP forwarding) is worth being able to read and write from memory.
- Forced/manual rotation (`logrotate -f`) is a realistic "disk is full right now" incident-response action — know the command and that you may still need to manually compress/clean the newly rotated (but not-yet-compressed) file if space is critical.
- `logrotate`'s state file (`/var/lib/logrotate/status`) is what makes rotation idempotent across repeated cron/timer invocations — know it exists when debugging "why didn't this rotate."
- Centralized/remote logging via rsyslog forwarding is foundational context for "how would you make logs survive a compromised or ephemeral host" — a common SRE/security-adjacent interview angle.
