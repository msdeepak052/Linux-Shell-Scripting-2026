# Troubleshooting Methodology: High CPU, Inode Exhaustion, Zombies, OOM Killer

These four scenarios are the recurring cast of "the box is unhealthy but the obvious metrics look fine" incidents — each has a specific, non-obvious diagnostic path that separates candidates who've actually been on-call from those who haven't.

## Explanation

**High CPU — find WHO and WHY, not just THAT**:
- `top`/`htop` sorted by `%CPU` identifies the process; `top -H -p <pid>` (or `htop` with threads shown) breaks it down **per-thread**, since one hot thread in a multi-threaded process is common.
- `pidstat -p <pid> 1` — per-process CPU over time, splits user vs system time (high `%system` often points to syscalls/context-switching/lock contention rather than raw compute).
- `strace -c -p <pid>` — syscall summary; a runaway syscall loop (`futex`, `poll`) points at contention, not compute-bound work.
- `perf top` — lowest-level answer: which functions/kernel symbols are actually burning cycles.
- Load average > core count sustained is the trigger to start this chain, but load average alone conflates CPU-bound and I/O-wait-bound load (check with `vmstat`'s `wa` column or `mpstat`).

**Disk "full" but `df` looks fine — inode exhaustion**:
- `df -h` shows free space by **blocks**; a filesystem can be 100% out of **inodes** (metadata entries, one per file) while blocks show plenty free — happens with directories holding millions of tiny files (session files, mail spools, cache dirs).
- `df -i` shows inode usage specifically — the diagnostic most people forget to run.
- Fix requires deleting files (freeing space doesn't free inodes, only removing files/directories does) — `find /path -type f | wc -l` to locate the offending directory, then clean it up.

**Zombie/defunct processes**:
- A zombie (`Z` state in `ps`) is a process that has **exited** but whose exit status hasn't been **reaped** by its parent via `wait()` — it holds only a PID table entry, no memory/CPU, but PIDs are a finite resource (`pid_max`), and enough zombies can exhaust the PID space.
- `ps aux | awk '$8=="Z"'` or `ps -eo pid,ppid,state,cmd | grep ' Z '` — find zombies and their **parent** PID.
- You cannot kill a zombie (it's already dead) — the fix targets the **parent**: either fix the parent's code to call `wait()`/`waitpid()`, or if the parent itself is broken/hung, restart the parent (its zombies get reparented to PID 1/init, which reaps them immediately).

**OOM killer investigation**:
- `dmesg -T | grep -i "out of memory\|killed process\|oom"` — kernel log shows OOM events with timestamps.
- `dmesg -T | grep -A2 "oom-kill"` shows the OOM score calculations and which process was selected (highest `oom_score` — roughly, biggest memory consumer adjusted by `oom_score_adj`).
- `/var/log/messages` or `journalctl -k` (kernel ring buffer via journald) — same info, persisted across reboots, whereas raw `dmesg` buffer is lost on reboot.
- `/proc/<pid>/oom_score` and `/proc/<pid>/oom_score_adj` — see/influence a specific process's OOM-kill likelihood (lower `oom_score_adj` protects a process, e.g., set to `-1000` to make it un-killable by the OOM killer).
- Exit code 137 on a container correlates strongly with OOM kill (128+SIGKILL) but must be confirmed via `dmesg`, not assumed.

## Hands-On Examples

**1. High CPU: identifying the hot thread inside a multi-threaded process**
```bash
$ top -H -p 4821
  PID   USER  %CPU  COMMAND
  4899  app   98.3  java
  4900  app    1.2  java
  4901  app    0.8  java

$ jstack 4821 | grep -A5 "nid=0x1323"     # 4899 in hex, correlate thread dump to hot thread
"pool-2-thread-3" #14 prio=5 tid=0x... nid=0x1323 runnable
   java.lang.Thread.run
   at com.app.CacheEvictor.run(CacheEvictor.java:44)   # infinite loop found
```

**2. High CPU: user vs system time split with `pidstat`**
```bash
$ pidstat -p 4821 1 5
Time    UID  PID   %usr  %system  %CPU  Command
10:05:01 1001 4821  12.0   84.0    96.0  java
```
84% system time with only 12% user — points to heavy syscall/context-switch overhead (lock contention, excessive GC, or a syscall loop), not raw application compute.

**3. Disk "full" but `df -h` shows space — classic inode exhaustion**
```bash
$ df -h /var
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda2        50G   12G   36G  25% /var

$ touch /var/spool/test
touch: cannot touch '/var/spool/test': No space left on device

$ df -i /var
Filesystem      Inodes  IUsed   IFree IUse% Mounted on
/dev/sda2      3276800 3276800     0  100% /var
```
`df -h` says 25% used (plenty of space); `df -i` reveals 100% of inodes consumed — this is the "full but not full" symptom.

**4. Finding what consumed all the inodes**
```bash
$ for d in /var/*; do echo "$d: $(find "$d" -xdev -type f 2>/dev/null | wc -l)"; done | sort -t: -k2 -n -r | head -5
/var/spool/postfix/maildrop: 2984021
/var/log: 12044
/var/cache: 3021

$ rm -rf /var/spool/postfix/maildrop/stuck-queue-*
$ df -i /var
Filesystem      Inodes  IUsed    IFree IUse% Mounted on
/dev/sda2      3276800 291822  2984978    9% /var
```

**5. Finding and diagnosing zombie processes**
```bash
$ ps -eo pid,ppid,state,cmd | awk '$3=="Z"'
  8821   8801  Z  [worker] <defunct>
  8830   8801  Z  [worker] <defunct>
  8841   8801  Z  [worker] <defunct>

$ ps -p 8801 -o pid,cmd
  PID CMD
 8801 python3 job_dispatcher.py
```
All zombies share parent PID 8801 — the dispatcher is spawning workers but never calling `wait()` on them.

**6. Fixing zombies — the parent, not the zombie, is the target**
```bash
$ kill -9 8821          # no effect — already dead, this does nothing
$ ps -p 8821
  PID CMD
 8821 [worker] <defunct>   # still there

$ sudo systemctl restart job-dispatcher   # restart the PARENT
$ ps -eo pid,ppid,state,cmd | awk '$3=="Z"'
# (empty — zombies reaped once their parent exited; orphans get reparented to PID 1 which reaps them)
```

**7. Confirming an OOM kill via `dmesg` and identifying the victim**
```bash
$ dmesg -T | grep -i "killed process" | tail -3
[Thu Aug  8 03:14:02 2026] Killed process 19233 (java) total-vm:4200000kB, anon-rss:3980000kB, ...

$ dmesg -T | grep -B15 "Killed process 19233" | grep -E "oom-kill|Out of memory"
[Thu Aug  8 03:14:02 2026] java invoked oom-killer: gfp_mask=0x..., order=0, oom_score_adj=0
[Thu Aug  8 03:14:02 2026] Out of memory: Killed process 19233 (java) score 891 or sacrifice child
```
`score 891` (near max 1000) shows the OOM killer's scoring picked this process as the largest/least-protected memory consumer.

**8. Protecting a critical process from the OOM killer, and checking journald persistence**
```bash
$ echo -500 | sudo tee /proc/$(pgrep -f critical-db)/oom_score_adj
$ cat /proc/$(pgrep -f critical-db)/oom_score_adj
-500

# journald keeps kernel logs across reboots, unlike the raw dmesg ring buffer
$ journalctl -k --since "2026-08-08 03:00" | grep -i oom
Aug 08 03:14:02 host01 kernel: Out of memory: Killed process 19233 (java) score 891
```

## Practice Questions

1. `top` shows a process at 300% CPU on an 8-core box. Walk through your next three diagnostic steps to find out WHAT it's doing, not just THAT it's busy.
2. `df -h` shows 30% disk usage but the application can't create new files ("No space left on device"). What's the likely cause, and what command confirms it?
3. Why can't freeing up disk space (e.g., truncating a large log file to 0 bytes) fix inode exhaustion? What actually needs to happen instead?
4. You find a dozen `<defunct>` processes via `ps`. Why does `kill -9` on a zombie PID have no effect, and what's the actual fix?
5. What's the difference between a zombie process and an orphan process? What happens to a zombie's parent PID slot changes to when the parent itself dies?
6. A container's exit code is 137. What does this number decompose to, and what specific `dmesg` output confirms (versus merely suggests) it was an OOM kill?
7. Explain `oom_score` and `oom_score_adj` — how would you protect a critical process (e.g., the primary database) from being OOM-killed before a less-important process on the same host?
8. Why does `dmesg` alone sometimes fail to show OOM events from before the last reboot, and what command/log source do you check instead?
9. `pidstat -p <pid> 1` shows 90% `%system` and 5% `%user` for a hot process. What does the high system-time-to-user-time ratio suggest about the root cause, compared to a process at 95% `%user`?
10. Design a one-liner (or short script) to find which directory under `/var` is consuming the most inodes, to diagnose an inode-exhaustion incident quickly.

## Real Interview Questions (Company-Attributed)

- "What is a zombie process?" — asked at *an unnamed company (via community-sourced interview notes)*
- "Explain the use of `lsof` for troubleshooting." — asked at *Sigmoid* (part of a rapid-fire "explain these Linux commands" interview round)

## Interview Key Points

- `df -i` (inodes) versus `df -h` (blocks) is one of the highest-yield "gotcha" questions in this space — a filesystem can be 100% out of inodes while blocks show mostly free, and only deleting files (not truncating them) frees inodes.
- Zombies cannot be killed — they're already dead; the fix always targets the **parent** process (fix its `wait()`/`waitpid()` logic, or restart it so orphaned zombies reparent to PID 1 and get reaped). This trips up almost everyone who hasn't hit it before.
- Exit code 137 strongly suggests OOM but must be **confirmed** via `dmesg`'s explicit "Out of memory: Killed process ... score ..." line — 137 alone is only 128+SIGKILL, which has other possible causes (manual kill, node preemption).
- High CPU debugging is a layered investigation, not a single command: `top -H` (which thread) -> `pidstat` (user vs system time split) -> `strace -c` or `perf top` (what it's actually doing at the syscall/function level) — know the full chain, not just `top`.
- High `%system` time (versus `%user`) redirects suspicion toward syscalls, lock contention, or excessive context switching rather than raw application compute — a nuance that separates surface-level from deep CPU debugging.
- `dmesg`'s in-memory ring buffer is lost on reboot; `journalctl -k` (or `/var/log/messages` on non-systemd/rsyslog setups) persists kernel logs across reboots — always know the persistent alternative for postmortems on issues discovered after a reboot.
- `oom_score_adj` is the direct, practical lever for protecting critical processes (e.g., primary databases) from being OOM-killed ahead of less critical ones on the same host — a concrete, actionable answer interviewers like to hear beyond "add more memory."
