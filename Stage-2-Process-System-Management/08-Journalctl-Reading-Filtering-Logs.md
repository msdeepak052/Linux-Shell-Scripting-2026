# `journalctl`: Reading & Filtering the systemd Journal

`journalctl` is the query interface for `systemd-journald`'s binary log store — knowing how to filter it fast (by unit, time, priority) is the difference between a 5-minute incident triage and a 45-minute one.

## Explanation

### How the journal works

`systemd-journald` collects logs from: unit stdout/stderr, the kernel ring buffer (`dmesg`), syslog-compatible sources, and structured messages via `sd_journal_print()`/`sd_notify()`. It stores them in a **binary, indexed format** (not plain text), which is what makes fast filtering by field possible.

**Volatile vs persistent storage** — configured in `/etc/systemd/journald.conf` via `Storage=`:
- `Storage=volatile` — logs kept only in `/run/log/journal/` (tmpfs) — **lost on reboot**. This is the default on many minimal/container images.
- `Storage=persistent` — logs kept in `/var/log/journal/` — **survives reboots**. Requires the directory to exist; `journald` auto-creates it if `Storage=persistent` is set, or you can pre-create it: `sudo mkdir -p /var/log/journal && sudo systemd-tmpfiles --create --prefix /var/log/journal`.
- `Storage=auto` (default in many distros) — persistent IF `/var/log/journal` exists, volatile otherwise.
- Size capped by `SystemMaxUse=` (default ~10% of filesystem, or `RuntimeMaxUse=` for volatile) — old entries are rotated/vacuumed out automatically.

### Core filtering flags

| Flag | Purpose |
|---|---|
| `-u <unit>` | Filter to one systemd unit (repeatable for multiple units) |
| `-f` | Follow mode, like `tail -f` |
| `-b` | Current boot only; `-b -1` = previous boot; `journalctl --list-boots` shows all recorded boots |
| `--since` / `--until` | Time range, accepts `"2026-08-08 09:00:00"`, `"1 hour ago"`, `yesterday`, `now` |
| `-p <priority>` | Minimum priority level (see table below) — `-p err` shows err and everything more severe |
| `-k` | Kernel messages only (like `dmesg`) |
| `-r` | Reverse order (newest first) |
| `-n <N>` | Last N lines (default 10, like `tail`) |
| `-o json-pretty` | Structured output — great for piping into `jq` |
| `-o cat` | Just the message text, no metadata (clean for grepping) |
| `--no-pager` | Don't page output — needed for scripting/piping |
| `-x` | Add explanatory help text for message IDs where available |
| `_PID=`, `_UID=`, `_COMM=` | Filter by structured journal fields |
| `--disk-usage` | How much space the journal is currently using |
| `--vacuum-size=` / `--vacuum-time=` | Manually trim journal size/age |

### Priority levels (syslog severity, low number = more severe)

`0 emerg`, `1 alert`, `2 crit`, `3 err`, `4 warning`, `5 notice`, `6 info`, `7 debug`

`-p warning` means "warning **and more severe**" (i.e., warning, err, crit, alert, emerg) — not just warning-level messages alone. This trips people up constantly.

### Combining filters

Multiple `-u` on the same run are OR'd (union of units). `--since`/`--until` combine with `-u`/`-p` as AND. Field matches (`journalctl _SYSTEMD_UNIT=nginx.service _PID=1234`) on the same invocation are AND'd unless separated by a bare `+` (OR).

## Hands-On Examples

**1. Logs for a single unit, most recent first**
```bash
$ journalctl -u nginx.service -n 20 --no-pager
Aug 08 09:58:02 web01 nginx[1220]: 2026/08/08 09:58:02 [error] 1220#1220: *44 connect() failed (111: Connection refused)
Aug 08 09:58:10 web01 systemd[1]: nginx.service: Main process exited, code=exited, status=1/FAILURE
Aug 08 09:58:10 web01 systemd[1]: nginx.service: Failed with result 'exit-code'.
Aug 08 09:58:15 web01 systemd[1]: nginx.service: Scheduled restart job, restart counter is at 3.
```

**2. Follow logs live, like `tail -f`, filtered to one unit**
```bash
$ journalctl -u myapp.service -f
Aug 08 10:12:01 web01 myapp[19011]: INFO  request completed in 42ms
Aug 08 10:12:03 web01 myapp[19011]: WARN  slow db query: 812ms
^C
```

**3. Only errors and worse, since a specific time**
```bash
$ journalctl -p err --since "2026-08-08 09:00:00" --no-pager
Aug 08 09:12:44 web01 kernel: nvme 0000:00:1f.0: I/O timeout
Aug 08 09:58:02 web01 nginx[1220]: [error] connect() failed (111: Connection refused)
```

**4. Logs from the current boot vs a previous boot (crash investigation)**
```bash
$ journalctl --list-boots
-2 3f1a9c2b... Fri 2026-08-06 22:01:03 UTC—Sat 2026-08-07 03:44:19 UTC
-1 8b7e4d11... Sat 2026-08-07 03:44:30 UTC—Sat 2026-08-08 06:00:02 UTC
 0 a91cf003... Sat 2026-08-08 06:00:15 UTC—Sat 2026-08-08 10:15:00 UTC

$ journalctl -b -1 -p err --no-pager | tail -20
# investigate what happened right before the previous reboot (e.g. OOM kill, panic)
```

**5. Relative and human time ranges**
```bash
$ journalctl --since "1 hour ago" -u myapp --no-pager
$ journalctl --since yesterday --until "1 hour ago" -u myapp --no-pager
$ journalctl --since "09:00" --until "09:15" -u myapp --no-pager
```

**6. Structured JSON output piped to `jq` for scripting/alerting**
```bash
$ journalctl -u myapp -p err -o json --since "10 min ago" | jq -r '.MESSAGE'
db connection pool exhausted
db connection pool exhausted
request timeout after 30s
```

**7. Multiple units at once + kernel messages for a full incident timeline**
```bash
$ journalctl -u myapp.service -u postgresql.service -k --since "09:55" --until "10:05" --no-pager
Aug 08 09:58:00 web01 kernel: TCP: request_sock_TCP: Possible SYN flooding on port 5432
Aug 08 09:58:02 web01 postgresql[901]: FATAL: remaining connection slots reserved
Aug 08 09:58:03 web01 myapp[19011]: ERROR: could not connect to database
```

**8. Checking / fixing journal storage — logs disappearing after reboot**
```bash
$ journalctl --disk-usage
Archived and active journals take up 48.2M in the file system.

$ cat /etc/systemd/journald.conf | grep -i storage
#Storage=auto

$ ls /var/log/journal/ 2>&1
ls: cannot access '/var/log/journal/': No such file or directory
# ^ explains why logs vanish on reboot: falling back to volatile /run/log/journal

$ sudo mkdir -p /var/log/journal
$ sudo systemd-tmpfiles --create --prefix /var/log/journal
$ sudo systemctl restart systemd-journald
$ sudo journalctl --disk-usage
```

## Practice Questions

1. A service crashed sometime overnight. Walk through the exact `journalctl` commands you'd run to find the root cause, from narrowing the boot down to the specific error.
2. What's the difference between `journalctl -p warning` and a filter that shows *only* warning-level messages? Why does this distinction matter when triaging?
3. After a reboot, `journalctl -u myapp -b -1` returns nothing even though the service was clearly running yesterday. What's the most likely configuration cause, and how do you fix it going forward?
4. How would you tail live logs for two different services simultaneously, filtered to error level or worse?
5. Write a command that outputs only error-level journal entries for `myapp.service` from the last hour, as JSON, and explain how you'd pipe that into a monitoring script.
6. What does `journalctl --disk-usage` show, and what commands would you use to cap the journal at 500MB or drop entries older than 2 weeks?
7. Explain the difference between `Storage=volatile`, `Storage=persistent`, and `Storage=auto` in `journald.conf`.
8. How do you get plain kernel-ring-buffer-style output (like classic `dmesg`) from journalctl, restricted to the current boot?
9. You need every log line for PID 19011 across all units it touched. What journalctl invocation gets you that using structured field matching?
10. Two engineers argue: one says journald replaces `/var/log/syslog` entirely, the other says both can coexist. Which is correct, and what determines it on a given system?

## Interview Key Points

- `-p <level>` filters "this level **and more severe**," not an exact match — a frequently misunderstood flag in interviews and in real triage.
- Know **volatile vs persistent** storage cold: default behavior varies by distro/image, and "why did my logs disappear after reboot" is a very common real-world question traced back to `/var/log/journal` not existing.
- `-b` / `-b -1` / `--list-boots` are essential for postmortems on crashes/reboots — a senior candidate should reach for these immediately when asked "the box rebooted overnight, find out why."
- `--no-pager` and `-o json`/`-o cat` matter for scripting — journalctl output isn't meant to be grepped raw with default formatting in automation.
- The journal is binary and indexed (unlike flat-file `/var/log/*.log`), which is *why* structured field filtering (`_PID=`, `_SYSTEMD_UNIT=`) and fast time-range queries are possible — worth explaining the "why" not just the "how."
- `journald` can coexist with traditional syslog (`rsyslog`/`syslog-ng`) via forwarding (`ForwardToSyslog=yes`) — it doesn't necessarily replace it; know this relationship for log-management architecture questions.
- Journal size is self-managing via rotation/vacuuming (`SystemMaxUse=`, `--vacuum-size=`, `--vacuum-time=`) — know how to manually reclaim disk space during an incident where `/var` fills up.
