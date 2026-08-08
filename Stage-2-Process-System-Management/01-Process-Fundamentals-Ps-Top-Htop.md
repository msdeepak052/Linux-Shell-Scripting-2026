# Process Fundamentals: `ps`, `ps aux`, `top`, `htop`

Every running program on Linux is a process with a PID, a resource footprint, and a state — `ps`, `top`, and `htop` are how you inspect that in production, from a one-shot snapshot to a live dashboard.

## Explanation

### `ps` — a snapshot, not a stream

`ps` prints the process table **at the instant you run it** and then exits — it does not refresh. Two historically different flag styles both work and get mixed constantly:

- **BSD style (no dash)**: `ps aux` — `a` = show processes for all users (not just yours), `u` = user-oriented output format (adds %CPU, %MEM, etc.), `x` = include processes without a controlling terminal (daemons/services).
- **UNIX/SysV style (with dash)**: `ps -ef` — `-e` = every process, `-f` = full-format listing (includes PPID, start time).

Both are extremely common; `ps aux` is more popular in casual/interview usage, `ps -ef` is more common in scripting because its columns are more consistently parseable (fixed-width UID/PID/PPID at the start).

Key `ps aux` columns:
```
USER  PID  %CPU  %MEM   VSZ    RSS   TTY   STAT  START  TIME   COMMAND
```
- `VSZ` — virtual memory size (everything the process *could* touch, including mapped-but-unused).
- `RSS` — resident set size, actual physical RAM currently in use — this is the number you care about for "is this process eating memory."
- `TTY` — controlling terminal (`?` means none, i.e. a daemon/service).
- `STAT` — process state code (see next topic file for the full state list); a `+` after it means foreground process group.
- `TIME` — cumulative **CPU** time consumed since start, not wall-clock uptime.

### `top` — live, but blocking your terminal

`top` refreshes in place (default every 3 seconds) and by default sorts by `%CPU` descending. It's interactive:
- `P` — sort by CPU (default), `M` — sort by memory, `T` — sort by running time.
- `k` — kill a process (prompts for PID then signal).
- `r` — renice a process.
- `1` — toggle per-core CPU breakdown instead of an aggregate line.
- `q` — quit.

The header block (load average, tasks, `%Cpu(s)`, `MiB Mem`) is often more valuable at a glance than the process list itself for a first-look triage.

### `htop` — `top` with a UX upgrade

`htop` is not installed by default on most minimal images (`apt install htop` / `dnf install htop`), which is itself an interview-relevant fact — you can't always assume it's there on a fresh/hardened server, but `top` and `ps` are always present. `htop` adds: color-coded, scrollable, mouse-clickable process list, a visual per-core CPU/memory meter bar at the top, tree view (`F5`) showing parent/child relationships, and easier in-place `kill`/`renice`/`nice` via function keys — `F9` kill, `F7`/`F8` renice.

### Which one should you actually use? (Decision rule)

| Situation | Use | Why |
|---|---|---|
| Scripting, cron jobs, piping into `grep`/`awk`, CI health checks | **`ps`** (usually `ps -ef` or `ps aux`) | Non-interactive, stable column output, always installed |
| Quick interactive look at what's consuming CPU/RAM right now | **`top`** | Always present on every Linux box, no install needed — the safe default when SSH'd into an unfamiliar/minimal server |
| Deep interactive investigation, sorting, tree view, or handing the terminal to someone less CLI-comfortable | **`htop`** | Nicer UX, but must be installed — don't rely on it being there |

**Bottom line: reach for `ps` inside scripts, `top` as your first live look on any box (it's guaranteed present), and install/use `htop` when you're doing sustained interactive investigation and can guarantee it's available.**

## Hands-On Examples

**1. Basic `ps aux` — full system snapshot**
```bash
$ ps aux | head -6
USER       PID  %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1   0.0  0.1 168420 11248 ?        Ss   08:02   0:03 /sbin/init
root       842   0.0  0.0  16104  6512 ?        Ss   08:02   0:00 /usr/sbin/sshd -D
www-data  2211   0.4  1.2 412088 98304 ?        Sl   09:14   3:27 /usr/bin/python3 /app/gunicorn
mysql     2340  12.8  8.5 2211080 683920 ?      Sl   09:14  41:09 /usr/sbin/mysqld
deepak    9981   0.0  0.0   9032  3384 pts/0    Ss   14:02   0:00 -bash
```

**2. Finding a specific process by name**
```bash
$ ps aux | grep -i nginx
root      1102  0.0  0.1  55984  9120 ?        Ss   08:02   0:00 nginx: master process /usr/sbin/nginx
www-data  1103  0.0  0.2  56420 11340 ?        S    08:02   0:12 nginx: worker process
$ pgrep -fl nginx
1102 nginx: master process /usr/sbin/nginx
1103 nginx: worker process
```

**3. `ps -ef` — the scripting-friendly variant, with PPID visible**
```bash
$ ps -ef | grep mysqld
mysql     2340     1 12  09:14 ?        00:41:09 /usr/sbin/mysqld
$ # PPID column (3rd field) = 1, meaning mysqld's parent is init/systemd (PID 1)
```

**4. Sorting `ps` output directly — no `top` needed for a one-shot check**
```bash
$ ps aux --sort=-%mem | head -4
USER       PID  %CPU %MEM    VSZ    RSS TTY      STAT START   TIME COMMAND
mysql     2340  12.8  8.5 2211080 683920 ?       Sl   09:14  41:09 /usr/sbin/mysqld
www-data  2211   0.4  1.2  412088  98304 ?       Sl   09:14   3:27 gunicorn
root         1   0.0  0.1  168420  11248 ?       Ss   08:02   0:03 /sbin/init
```

**5. `top` batch mode — for logging/monitoring pipelines instead of an interactive session**
```bash
$ top -bn1 | head -12
top - 14:32:07 up 6 days,  6:30,  2 users,  load average: 3.42, 2.87, 2.15
Tasks: 187 total,   2 running, 184 sleeping,   0 stopped,   1 zombie
%Cpu(s): 62.3 us,  8.1 sy,  0.0 ni, 27.4 id,  1.9 wa,  0.0 hi,  0.3 si,  0.0 st
MiB Mem :  16034.0 total,   1204.3 free,  12980.1 used,   1849.6 buff/cache
MiB Swap:   2048.0 total,   1980.0 free,     68.0 used.   2740.5 avail Mem

  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
 2340 mysql     20   0    2.1g 683920 41200  S  92.3   4.3  41:09.44 mysqld
 2211 www-data  20   0  412088  98304  9120  S  18.7   0.6   3:27.90 gunicorn
```
`-bn1` = batch mode, run exactly one iteration — this is what you'd embed in a cron job or health-check script since interactive `top` never exits on its own.

**6. Production scenario: a box is sluggish, load average is high — first-look triage**
```bash
$ uptime
 14:35:02 up 6 days,  6:33,  2 users,  load average: 8.91, 6.40, 4.02
$ top -bn1 | head -5
top - 14:35:02 up 6 days,  6:33,  2 users,  load average: 8.91, 6.40, 4.02
Tasks: 190 total,   4 running, 185 sleeping,   0 stopped,   1 zombie
%Cpu(s): 95.1 us,  4.2 sy,  0.0 ni,  0.1 id,  0.6 wa,  0.0 hi,  0.0 si,  0.0 st
MiB Mem :  16034.0 total,    210.4 free,  15100.9 used,    722.7 buff/cache
```
Load average (8.91) far above the core count and `%CPU` user-time near 95% with almost no idle → CPU-bound, not I/O-wait. Next step: find which process.
```bash
$ ps aux --sort=-%cpu | head -3
USER       PID  %CPU %MEM    VSZ    RSS TTY      STAT START   TIME COMMAND
deploy    30122  97.4  2.1 891200 168300 ?       R    14:20   3:12 /usr/bin/python3 batch_job.py
```

**7. `htop` — reading the header meters (interactive, described here since it can't be "captured" like a log)**
```bash
$ htop
```
```
  1[||||||||||||||||||||100.0%]   Tasks: 62, 189 thr; 3 running
  2[||||||||||||       48.2%]    Load average: 3.42 2.87 2.15
  3[||||                12.0%]    Uptime: 6 days, 06:30:44
  4[|                    4.1%]
  Mem[||||||||||||||||12.7G/15.6G]
  Swp[|                68.0M/2.00G]

    PID USER      PRI  NI  VIRT   RES   SHR S CPU% MEM%   TIME+  Command
   2340 mysql      20   0  2211M  683M  41M S 92.3  4.3  41:09.44 /usr/sbin/mysqld
```
Per-core bars instantly show core 1 pegged at 100% while others are idle — a strong hint of a single-threaded process bottleneck, which is harder to spot from `top`'s single aggregate `%Cpu(s)` line unless you press `1` there too.

**8. Real troubleshooting: distinguishing a memory leak from normal usage over time**
```bash
$ while true; do ps -o pid,rss,vsz,cmd -p 30122 --no-headers; sleep 30; done
30122  168300  891200 python3 batch_job.py
30122  245600  891200 python3 batch_job.py
30122  398200  891200 python3 batch_job.py
30122  571300  891200 python3 batch_job.py
```
`RSS` climbing steadily every 30s while `VSZ` stays flat is the classic signature of a memory leak (growing resident usage, not just address space) — worth knowing as a diagnostic pattern, not just command syntax.

## Practice Questions

1. What's the actual difference between `VSZ` and `RSS` in `ps aux` output, and which one should you look at if you're worried a process is about to get OOM-killed?
2. Why does `ps aux` show `mysqld`'s `TIME` column as `41:09` after only 25 minutes of wall-clock uptime? What does the `TIME` column actually measure?
3. A process shows `TTY` as `?` in `ps aux` — what does that tell you about how it was started?
4. Write a command that finds the top 5 processes by memory usage without opening `top` interactively (i.e., suitable for a script/cron job).
5. Your server's load average is 12 on a 4-core box, but `%CPU` user time is low and `wa` (I/O wait) is high in `top`. What does that combination suggest, and what would you check next?
6. What's the difference between `ps aux` and `ps -ef`, and why might a script prefer one over the other for reliable field parsing?
7. `htop` isn't installed on a production box you just SSH'd into and you don't have package-install permissions right now — what do you fall back to, and what do you lose?
8. You suspect a process has a memory leak. Describe a one-liner or short loop to confirm RSS is growing over time rather than just being high once.
9. In `top`'s header, what's the difference between the `%Cpu(s)` `us`, `sy`, and `wa` fields, and what does a high `wa` specifically indicate?
10. Explain why `ps` is described as a "snapshot" — what does that imply about using a single `ps` invocation to diagnose an intermittent CPU spike that only lasts 2 seconds?

## Real Interview Questions (Company-Attributed)

- "How do you check running processes in Linux?" — asked at *Arrise Solutions*
- "When you run the `top` command, what components/columns are displayed?" — asked at *Arrise Solutions*
- "How do you check a Linux process without using `ps` or `top`?" — asked at *Verizon*
- "Write a script to count how many processes are running under a given user (e.g. `ubuntu`)." — asked at *Nitor Infotech*
- "What is a PID?" — asked at *CMT*

## Interview Key Points

- **`ps` is a one-shot snapshot; `top`/`htop` are live/refreshing** — this distinction matters for diagnosing intermittent issues (a single `ps` call can miss a 2-second spike; `top`/`watch ps` or logging loops don't).
- **RSS vs VSZ**: RSS is actual physical memory in use (what matters for OOM risk); VSZ includes virtual/mapped memory that may never be touched — a very common "what do these columns mean" interview probe.
- **`ps aux` (BSD-style, no dash) vs `ps -ef` (UNIX-style)** — know both exist and are equivalent in intent; `-ef` is favored in scripts for consistent field parsing.
- **`htop` is not guaranteed to be installed**, especially on minimal/hardened images — `ps` and `top` are always available; don't build a troubleshooting habit that assumes `htop` exists.
- Know how to read **load average vs `%CPU`** together: high load + high `us` CPU = CPU-bound; high load + high `wa` = I/O-bound; being able to tell these apart from `top`'s header is a strong signal of real production experience.
- `top -bn1` (batch mode, one iteration) is the answer whenever asked "how would you capture `top` output in a script/cron/log" — plain interactive `top` never terminates on its own.
- Sorting: `ps aux --sort=-%cpu` / `--sort=-%mem` for one-shot ranked snapshots; `top`'s `P`/`M` keys and `htop`'s clickable columns for interactive ranking — know the non-interactive equivalent since that's what scripting/monitoring questions actually ask for.
