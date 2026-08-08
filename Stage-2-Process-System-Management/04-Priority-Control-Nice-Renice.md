# Priority Control: `nice`, `renice`

The Linux scheduler decides who gets CPU time next — `nice` and `renice` are how you nudge that decision without actually pausing or killing anything.

## Explanation

### The nice value

Every process has a **niceness** value from **-20 (highest priority) to +19 (lowest priority)**, defaulting to **0**. The name is intentionally backwards from intuition: a *higher* nice value means the process is being "nicer" to everyone else — i.e. more willing to yield CPU — hence *lower* scheduling priority. This trips people up constantly: -20 is NOT "negative/bad priority," it's the most aggressive/highest priority a process can have.

Nice value is only a **hint/weight** to the CFS (Completely Fair Scheduler) — it influences how much CPU time a process gets relative to others when they're competing for the CPU, but it does **not** guarantee reserved CPU, and it has **zero effect** if the CPU isn't actually contended (a niced-down process still runs at full speed on an idle core).

### `nice` — set priority at launch time

```bash
nice -n <value> command      # start a NEW process with a specific nice value
```
Without `-n`, `nice command` defaults to niceness 10. You cannot `nice` an already-running process — that's what `renice` is for.

### `renice` — change priority of a running process

```bash
renice -n <value> -p <PID>            # by PID
renice -n <value> -u <username>       # ALL processes owned by a user
renice -n <value> -g <groupname>      # ALL processes in a process group
```

### Permission rules — a genuine gotcha

- **Regular (non-root) users can only INCREASE their own process's nice value** (make it "nicer"/lower priority), i.e. move it toward +19. They **cannot** decrease it (cannot make their own process higher priority than default), and **cannot** touch other users' processes at all.
- **Only root can set negative nice values** (higher priority than default) or renice any process, including other users'.
- A regular user who renices their own process to +10 **cannot renice it back down to 0** — that would be a priority *increase*, which is blocked for non-root.

### Priority vs `PR` column in `top`/`ps`

`top`/`ps` show both `NI` (the nice value you set) and `PR` (the actual kernel scheduling priority, which for normal processes = `20 + NI`, i.e. `PR` ranges 0-39 while `NI` ranges -20 to 19). Real-time processes (a different scheduling class entirely, `chrt`/`SCHED_FIFO`/`SCHED_RR`) show `PR` as `rt` and are outside the nice-value system altogether — a nuance worth mentioning if the topic comes up.

### Which one should you actually use? (Decision rule)

| Situation | Use | Why |
|---|---|---|
| Launching a new batch/background job that shouldn't compete with interactive/critical workloads | **`nice -n 10 command`** | Set the priority at process creation |
| A job is already running and hogging CPU, and you don't want to kill/restart it | **`renice -n 15 -p <PID>`** | Adjusts a live process in place |
| You need a process to get *more* CPU priority than default | **`sudo nice -n -10 command`** or **`sudo renice -n -10 -p <PID>`** | Negative values require root — plan for `sudo` |
| You want to throttle every process for one user (e.g. a shared analytics user account) | **`renice -n 10 -u analytics`** | One command instead of looping over PIDs |

**Bottom line: `nice` sets priority at launch, `renice` adjusts it after the fact — reach for `nice` when writing/scheduling a new job, and `renice` when you're actively firefighting a CPU-hogging process you don't want to restart.**

## Hands-On Examples

**1. Checking default niceness**
```bash
$ sleep 100 &
[1] 32001
$ ps -o pid,ni,pri,cmd -p 32001
    PID  NI PRI CMD
  32001   0  19 sleep 100
```

**2. Launching a new process with a lower priority**
```bash
$ nice -n 15 tar -czf /backups/full_backup.tar.gz /data &
[1] 32050
$ ps -o pid,ni,pri,cmd -p 32050
    PID  NI PRI CMD
  32050  15   4 tar -czf /backups/full_backup.tar.gz /data
```
Notice: higher `NI` (15) correlates with lower `PRI` (4) — exactly the "nice = polite = lower priority" relationship.

**3. `nice` with no value — the implicit default of 10**
```bash
$ nice sleep 200 &
[1] 32090
$ ps -o pid,ni,cmd -p 32090
    PID  NI CMD
  32090  10 sleep 200
```

**4. `renice` on an already-running process**
```bash
$ ps aux | grep batch_job
deploy   30122  97.4  2.1 891200 168300 ?   R    14:20   3:12 python3 batch_job.py
$ renice -n 19 -p 30122
30122 (process ID) old priority 0, new priority 19
$ ps -o pid,ni,cmd -p 30122
    PID  NI CMD
  30122  19 python3 batch_job.py
```

**5. Permission boundary — non-root trying to go negative**
```bash
$ whoami
deploy
$ renice -n -5 -p 30122
renice: failed to set priority for 30122 (process ID): Permission denied
$ sudo renice -n -5 -p 30122
30122 (process ID) old priority 19, new priority -5
```

**6. Non-root trying to lower (increase priority) a value they already raised**
```bash
$ nice -n 10 ./my_script.sh &
[1] 32200
$ renice -n 0 -p 32200
renice: failed to set priority for 32200 (process ID): Permission denied
$ # as non-root, once you've niced UP, you can't nice back DOWN toward 0 or below
```

**7. Reniceing every process for a user at once (shared analytics box scenario)**
```bash
$ ps -u analytics -o pid,ni,cmd
    PID  NI CMD
  40011   0  python3 report_gen.py
  40033   0  python3 etl_pipeline.py
$ sudo renice -n 10 -u analytics
1000 (user ID) old priority 0, new priority 10
$ ps -u analytics -o pid,ni,cmd
    PID  NI CMD
  40011  10  python3 report_gen.py
  40033  10  python3 etl_pipeline.py
```

**8. Real scenario: CPU-heavy backup job stepping on a latency-sensitive web app**
```bash
$ top -bn1 | head -10
%Cpu(s): 98.2 us,  1.5 sy,  0.0 ni,  0.1 id,  0.2 wa
  PID USER      PR  NI    %CPU  COMMAND
30500 backup    20   0    91.0  rsync
 2211 www-data  20   0     6.2  gunicorn
```
`rsync` is starving `gunicorn` of CPU at the same default priority. Fix without killing the backup:
```bash
$ sudo renice -n 19 -p 30500
30500 (process ID) old priority 0, new priority 19
$ top -bn1 | head -10
%Cpu(s): 40.1 us, 1.2 sy, 0.0 ni, 58.4 id, 0.3 wa
  PID USER      PR  NI    %CPU  COMMAND
 2211 www-data  20   0    55.3  gunicorn
30500 backup    39  19    38.9  rsync
```
`gunicorn`'s throughput recovers immediately because the scheduler now favors it under contention — `rsync` still makes progress, just yields CPU when something else wants it.

## Practice Questions

1. Why does a nice value of -20 mean *higher* priority, when intuitively "negative" sounds worse? Explain the "niceness = politeness" mental model.
2. What's the actual functional difference between `nice` and `renice`? When would you have to use one instead of the other?
3. A non-root user runs `nice -n 10 ./script.sh` and later tries `renice -n 5 -p <pid>` on it to lower it slightly. Why does this fail, and who CAN do it?
4. What does the `PR` column in `top`/`ps` represent, and how does it relate to the `NI` (nice) value for a normal (non-realtime) process?
5. You renice a CPU-hogging process to +19 on an otherwise-idle 16-core server. Does its actual throughput change? Why or why not?
6. Write a command to launch a `tar` backup job at the lowest possible scheduling priority a non-root user can set.
7. Write a command that lowers the priority (raises nice value) of every process owned by a specific user, in one shot, without looping over PIDs individually.
8. A teammate says "nice guarantees a process gets less CPU." What's inaccurate about that statement, and what does nice actually control?
9. If you need a critical monitoring process to get *higher* than default priority, what command(s) would you use, and what privilege do you need?
10. What's the difference between adjusting a process's nice value and adjusting its I/O priority (`ionice`)? (Bonus: why might a CPU-light but I/O-heavy process need the latter instead?)

## Real Interview Questions (Company-Attributed)

- "Explain the use of the `nice` command." — asked at *Sigmoid* (part of a rapid-fire "explain these Linux commands" interview round)

## Interview Key Points

- **Nice values range -20 (highest priority) to +19 (lowest priority), default 0** — memorize the range and the inverted-intuition direction; this is asked almost verbatim in most Linux interviews.
- **`nice` sets priority when STARTING a new process; `renice` changes it on an ALREADY-RUNNING process** — the core functional distinction, and a common "which command would you use here" scenario question.
- **Permission model**: non-root users can only raise their own process's nice value (lower priority) and can never lower it back down or touch other users' processes; only root can set negative values or renice arbitrary processes — a frequently-tested gotcha.
- Nice/renice is a **scheduling hint, not a hard resource reservation** — on an uncontended/idle system, a heavily niced process still runs at full speed; the effect only shows up under CPU contention. Stating this nuance distinguishes senior-level understanding from rote memorization.
- Know the relationship **`PR = 20 + NI`** (for normal, non-realtime processes) as shown in `top`/`ps` — and that realtime-scheduled processes (`chrt`) sit outside the nice system entirely, shown as `PR` = `rt`.
- Common real-world use case to mention unprompted: **niceing down backup/batch/cron jobs (`rsync`, `tar`, ETL scripts) so they don't starve latency-sensitive services** sharing the same host — this is the practical "why does this matter" answer interviewers want.
- `ionice` is the I/O-scheduling analog of `nice` (CPU) — worth knowing it exists as a related-but-different lever, since a process can be CPU-light yet I/O-heavy and starve others on disk access instead of CPU.
- Be ready to walk through a full incident scenario: identify the offending process via `top`/`ps --sort=-%cpu`, decide renice vs kill based on whether the job still needs to complete, then verify improvement — this narrative-style answer plays much better than reciting flag syntax alone.
