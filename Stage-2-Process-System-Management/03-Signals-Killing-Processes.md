# Signals & Killing Processes: `kill`, `killall`, `pkill`, Signal Numbers

`kill` doesn't just terminate — it sends a signal, and picking the right one (and the right targeting tool) is one of the most-tested practical skills in Linux interviews.

## Explanation

### Signals are messages, not just "kill"

A signal is an asynchronous notification delivered to a process by the kernel. `kill` is a misleading name — it sends *any* signal, not only termination ones, and most signals can be caught, ignored, or handled by the receiving process (a few cannot be, by design).

Signals every senior engineer should know cold:

| Signal | Number | Default action | Can be caught/ignored? | Typical use |
|---|---|---|---|---|
| `SIGHUP` | 1 | Terminate | Yes | Terminal hangup; conventionally repurposed by daemons (nginx, sshd, rsyslog) to mean "reload config" |
| `SIGINT` | 2 | Terminate | Yes | What `Ctrl+C` sends to the foreground process |
| `SIGQUIT` | 3 | Terminate + core dump | Yes | `Ctrl+\` — like SIGINT but requests a core dump |
| `SIGKILL` | 9 | Terminate | **No — cannot be caught, blocked, or ignored** | Force-kill, last resort |
| `SIGSEGV` | 11 | Terminate + core dump | Yes | Invalid memory access (segfault) |
| `SIGTERM` | 15 | Terminate | Yes | **Default signal `kill` sends** — polite "please shut down" |
| `SIGSTOP` | 19 | Stop process | **No — cannot be caught, blocked, or ignored** | Pause execution (like `SIGKILL`, unblockable) |
| `SIGCONT` | 18 | Resume | Yes | Resume a stopped process |
| `SIGTSTP` | 20 | Stop process | Yes | What `Ctrl+Z` sends (catchable, unlike `SIGSTOP`) |

The critical fact: **`SIGKILL` (9) and `SIGSTOP` (19) are the only two signals a process cannot intercept, block, or handle** — the kernel enforces them directly, which is exactly why `SIGKILL` is the guaranteed-to-work last resort when a process is unresponsive.

### `SIGTERM` vs `SIGKILL` — the graceful-shutdown question

`SIGTERM` is a *request*: the process gets a chance to run its signal handler, flush buffers, close file descriptors/database connections, save state, and exit cleanly. `SIGKILL` is *immediate death* at the kernel level — no cleanup, no handler runs, connections/file locks/temp files can be left in a bad state. The standard production pattern (and what systemd itself does) is: send `SIGTERM`, wait a grace period (systemd defaults to 90s, configurable via `TimeoutStopSec`), and only escalate to `SIGKILL` if the process hasn't exited by then.

### `kill` vs `killall` vs `pkill` — targeting mechanism differs

- **`kill <PID>`** — targets by exact PID only. Requires you to already know the PID (from `ps`/`pgrep`). Safest — zero ambiguity about what you're signaling.
- **`killall <name>`** — targets by **exact process name** (as shown in `ps`/`comm`), kills **all matching processes** at once. Dangerous on multi-tenant boxes: `killall python3` kills every python3 process for every user/app on that host.
- **`pkill <pattern>`** — targets by regex/pattern match against the process name or full command line (`-f` flag matches the full cmdline, not just the binary name), also kills all matches. More flexible than `killall` but the pattern-matching power cuts both ways — a loose pattern can match far more than intended.

Both `killall` and `pkill` support `-<signal>` the same way `kill` does: `pkill -9 -f myapp.py`.

### Which one should you actually use? (Decision rule)

| Situation | Use | Why |
|---|---|---|
| You already have the exact PID (from `ps`, `pgrep`, a pidfile) | **`kill <PID>`** | No ambiguity — safest option |
| You need to find the PID by name/pattern first, then kill it, in a script | **`pkill -f "pattern"`** | One step instead of `pgrep` + `kill`; use `-f` to match the full command line for precision (e.g. distinguish `python3 app.py` from `python3 other.py`) |
| You genuinely want to kill *every* instance of a named binary system-wide (e.g. clearing all leftover test runners) | **`killall <name>`** | Matches exact binary name only — less surprising than a loose `pkill` regex, but still be sure you mean "all of them" |
| Interactive, one-off, you can see the PID in `top`/`htop` | **`kill <PID>`** or `top`'s `k` | Fastest when already looking at process list |

**Bottom line: default to `kill <PID>` when you know the PID; reach for `pkill -f` with a precise pattern in scripts/automation; treat `killall` and loose `pkill` patterns as blunt instruments that need a second look before running on a shared host.**

## Hands-On Examples

**1. Sending default `SIGTERM`**
```bash
$ ps aux | grep batch_job
deploy   30122  97.4  2.1 891200 168300 ?        R    14:20   3:12 python3 batch_job.py
$ kill 30122
$ ps aux | grep batch_job
$ # gone — process caught SIGTERM (or had no handler, so default action ran) and exited
```

**2. Escalating to `SIGKILL` when `SIGTERM` is ignored**
```bash
$ kill 30122
$ sleep 5
$ ps -p 30122
    PID TTY          TIME CMD
  30122 ?        00:03:12 batch_job.py       # still alive — process is ignoring/catching SIGTERM
$ kill -9 30122
$ ps -p 30122
$ # gone — SIGKILL cannot be caught or ignored, guaranteed to terminate it
```

**3. Signal by name vs number — both work identically**
```bash
$ kill -SIGTERM 30122
$ kill -TERM 30122      # SIG prefix optional
$ kill -15 30122        # numeric form — all three lines are equivalent
```

**4. Listing all available signals**
```bash
$ kill -l | head -3
 1) SIGHUP	 2) SIGINT	 3) SIGQUIT	 4) SIGILL	 5) SIGTRAP
 6) SIGABRT	 7) SIGBUS	 8) SIGFPE	 9) SIGKILL	10) SIGUSR1
11) SIGSEGV	12) SIGUSR2	13) SIGPIPE	14) SIGALRM	15) SIGTERM
```

**5. `pkill -f` — precise pattern matching on the full command line**
```bash
$ ps aux | grep python3
deploy   30122  0.5  1.1 210000 88000 ?    S    09:00   0:20 python3 /app/worker.py --queue=high
deploy   30190  0.2  0.9 198000 71000 ?    S    09:01   0:11 python3 /app/worker.py --queue=low

$ pkill -f "worker.py --queue=high"     # only matches ONE of the two — precise
$ ps aux | grep python3
deploy   30190  0.2  0.9 198000 71000 ?    S    09:01   0:11 python3 /app/worker.py --queue=low
```
Without `-f`, `pkill worker.py` wouldn't match at all here (default matches only the process *name*, `python3`, not its arguments) — a common real-world gotcha.

**6. `killall` — the "kill every instance" blunt instrument**
```bash
$ killall node
$ # every process literally named 'node' across ALL users on this host is now dead
```
On a shared/multi-tenant box this is dangerous — `killall` has no concept of "just mine"; always confirm ownership first with `ps -u $(whoami) | grep node` if that's the intent.

**7. `SIGHUP` for config reload, not termination — a real ops pattern**
```bash
$ ps aux | grep nginx
root      1102  0.0  0.1  55984  9120 ?        Ss   08:02   0:00 nginx: master process
$ vim /etc/nginx/nginx.conf   # edit config
$ kill -HUP 1102
$ tail -1 /var/log/nginx/error.log
2026/08/08 14:41:02 [notice] 1102#1102: signal process started

$ # nginx is still running with the SAME pid, but has reloaded config — no dropped connections
$ ps aux | grep 1102
root      1102  0.0  0.1  55984  9124 ?        Ss   08:02   0:00 nginx: master process
```

**8. Production incident: runaway process ignoring SIGTERM, verified before force-kill**
```bash
$ ps -o pid,ppid,stat,cmd -p 30122
    PID    PPID STAT CMD
  30122   9981  S    python3 batch_job.py

$ timeout 5 kill 30122 2>/dev/null; kill -0 30122 2>/dev/null && echo "still alive after grace period"
still alive after grace period

$ # confirmed still running after a 5s grace period, safe to escalate:
$ kill -9 30122
$ kill -0 30122 2>/dev/null || echo "confirmed dead"
confirmed dead
```
`kill -0` sends no actual signal — it just checks whether the PID exists and you have permission to signal it, making it the standard "is this process still alive" check in scripts.

## Practice Questions

1. What's the actual difference between `SIGTERM` and `SIGKILL`, and why should you always try `SIGTERM` first in a production shutdown?
2. Why is it impossible for a process to ignore `SIGKILL` or `SIGSTOP`, when it CAN ignore `SIGTERM` or even `SIGINT`?
3. You run `kill -9 <PID>` on a database process mid-write. What's the practical risk of using SIGKILL here versus SIGTERM?
4. What's the difference between `kill`, `killall`, and `pkill` in terms of how each identifies its target process(es)?
5. Why does `pkill worker.py` (no `-f`) fail to match a process running as `python3 /app/worker.py`, and how do you fix the command?
6. What does `kill -HUP <pid>` traditionally do to a long-running daemon like nginx or rsyslog, and how is that different from actually killing and restarting it?
7. Write a command sequence that sends SIGTERM to a process, waits a few seconds, checks if it's still alive, and only then sends SIGKILL.
8. What does `kill -0 <pid>` do, and why is it useful in a script even though it never actually signals the process to do anything?
9. On a shared multi-tenant server, why is `killall myapp` risky compared to targeting a specific PID? Give a concrete scenario where it causes collateral damage.
10. What's the numeric signal value for SIGTERM and SIGKILL, and why might you see an exit code of `137` or `143` for a process in a monitoring/orchestration system (hint: think 128 + signal number)?

## Real Interview Questions (Company-Attributed)

- "How do you kill a running process?" — asked at *Arrise Solutions*
- "Give a command to find a process and kill it." — asked at *an unnamed company (via community-sourced interview notes)*
- "What's the difference between `kill` and `kill -9`, and how many total signals does Linux define?" — asked at *Verizon*

## Interview Key Points

- **`SIGTERM` (15) is the default, catchable, "please clean up and exit" signal; `SIGKILL` (9) is unconditional, immediate, and uncatchable** — the single most-asked distinction in this topic area, know it instantly.
- **Only `SIGKILL` and `SIGSTOP` cannot be caught, blocked, or ignored by a process** — everything else (including `SIGINT`, `SIGQUIT`, even `SIGTERM`) can be intercepted by a signal handler, which is why some processes appear to "ignore" `Ctrl+C` or `kill` without `-9`.
- **Always attempt `SIGTERM` before escalating to `SIGKILL`** in production — this is exactly what systemd does on `systemctl stop` (`SIGTERM`, then `TimeoutStopSec` grace period, then `SIGKILL`); stating this pattern unprompted signals real operational experience.
- **`kill` targets by PID (precise), `killall` targets by exact process name (all matches), `pkill` targets by regex/pattern (all matches, `-f` for full cmdline)** — know the targeting mechanism difference, not just "they all kill things."
- `SIGHUP` is commonly repurposed by long-running daemons (nginx, sshd, rsyslog) to mean "reload configuration without restarting" — a strong "gotcha, this isn't just about hangup" interview point.
- `kill -0 <pid>` sends no signal at all — it's purely an existence/permission check, and it's the idiomatic way scripts test "is this PID still running" without side effects.
- Exit codes above 128 encode "killed by signal": `128 + signal number` — 137 = SIGKILL (128+9), 143 = SIGTERM (128+15); recognizing 137 in Kubernetes/Docker exit codes as "this container was OOM-killed or force-killed" is a real production-debugging skill interviewers probe for.
- `pkill`/`killall` without a precise pattern are genuinely dangerous on shared hosts — always know (or demonstrate you'd check) exactly what you're about to match before running them non-interactively.
