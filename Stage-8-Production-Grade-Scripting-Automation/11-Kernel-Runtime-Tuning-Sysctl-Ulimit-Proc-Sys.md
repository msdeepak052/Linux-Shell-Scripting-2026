# Kernel/Runtime Tuning: `sysctl`, `ulimit`, `/proc`, `/sys`

Most "mystery" production issues at scale — connection exhaustion, "too many open files," dropped packets under load — trace back to a kernel or process limit nobody tuned, discoverable only by reading `/proc` and `/sys` directly.

## Explanation

**`sysctl`** — read/write kernel runtime parameters (the same values living under `/proc/sys/`).
- `sysctl -a` — dump all current parameters.
- `sysctl <param>` — read one, e.g. `sysctl net.ipv4.ip_forward`.
- `sysctl -w <param>=<value>` — set at runtime (does NOT survive reboot).
- `/etc/sysctl.conf` or `/etc/sysctl.d/*.conf` + `sysctl -p` — persist across reboots.
- Common production-relevant params: `net.core.somaxconn` (max backlog for listening sockets), `net.ipv4.tcp_tw_reuse` (reuse TIME_WAIT sockets), `net.ipv4.ip_local_port_range` (ephemeral port range, matters for high-connection-count services), `vm.swappiness` (how aggressively the kernel swaps), `vm.max_map_count` (max memory-mapped areas per process, famously needs raising for Elasticsearch), `fs.file-max` (system-wide open file limit), `net.ipv4.tcp_fin_timeout`.

**`ulimit`** — per-process/per-shell resource limits, a **soft** ceiling (adjustable up to the **hard** limit by the process itself) enforced by `setrlimit()`.
- `ulimit -n` — max open file descriptors (the classic "too many open files" limit).
- `ulimit -u` — max user processes/threads.
- `ulimit -a` — show all current limits.
- `ulimit -Hn` / `-Sn` — hard vs soft limit for file descriptors specifically.
- Set persistently via `/etc/security/limits.conf` (PAM-based, applies to login sessions) — but **systemd services do NOT read `limits.conf`** by default; they need `LimitNOFILE=` etc. in the unit file's `[Service]` section instead. This split is one of the most common real-world gotchas.
- A process can only ever raise its soft limit up to its hard limit (unprivileged); raising the hard limit itself requires root or `CAP_SYS_RESOURCE`.

**`/proc`** — a virtual filesystem exposing live kernel/process state, no special tooling needed, just `cat`/`read`.
- `/proc/<pid>/status` — memory (`VmRSS`), state, threads, UID.
- `/proc/<pid>/limits` — the actual effective ulimits for that specific running process (ground truth, better than assuming from shell config).
- `/proc/<pid>/fd/` — list of open file descriptors (count them for "too many open files" diagnosis: `ls /proc/<pid>/fd | wc -l`).
- `/proc/meminfo`, `/proc/cpuinfo`, `/proc/loadavg`, `/proc/uptime` — system-wide stats, what tools like `free`/`uptime` parse under the hood.
- `/proc/sys/` — the same tree `sysctl` reads/writes; `cat /proc/sys/net/ipv4/ip_forward` == `sysctl net.ipv4.ip_forward`.

**`/sys`** — exposes kernel objects (devices, cgroups, block devices, network interfaces) as a structured filesystem, largely superseding older `/proc` uses for device/driver info.
- `/sys/fs/cgroup/...` — cgroup controllers/limits (see the namespaces/cgroups file for detail).
- `/sys/block/<dev>/queue/...` — block device I/O scheduler, queue depth, readahead settings.
- `/sys/class/net/<iface>/...` — network interface stats/settings (`/sys/class/net/eth0/statistics/rx_dropped`).

## Hands-On Examples

**1. Diagnosing "too many open files" — the classic production incident**
```bash
$ systemctl status myapp | grep -A3 Main
Main PID: 4821

$ cat /proc/4821/limits | grep "open files"
Max open files            1024                 4096                 files

$ ls /proc/4821/fd | wc -l
1021
```
The process is at 1021/1024 — nearly exhausted its soft limit, about to start throwing "too many open files" errors.

**2. Fixing it for a systemd service (NOT `/etc/security/limits.conf` — that's ignored by systemd units)**
```bash
$ sudo mkdir -p /etc/systemd/system/myapp.service.d/
$ cat <<'EOF' | sudo tee /etc/systemd/system/myapp.service.d/limits.conf
[Service]
LimitNOFILE=65536
EOF
$ sudo systemctl daemon-reload
$ sudo systemctl restart myapp
$ cat /proc/$(pgrep -f myapp)/limits | grep "open files"
Max open files            65536                65536                files
```

**3. Tuning `net.core.somaxconn` for a service under heavy connection load**
```bash
$ sysctl net.core.somaxconn
net.core.somaxconn = 128

$ sudo sysctl -w net.core.somaxconn=4096
net.core.somaxconn = 4096

# Persist it
$ echo "net.core.somaxconn = 4096" | sudo tee -a /etc/sysctl.d/99-tuning.conf
$ sudo sysctl -p /etc/sysctl.d/99-tuning.conf
```

**4. Elasticsearch's famous `vm.max_map_count` requirement**
```bash
$ sysctl vm.max_map_count
vm.max_map_count = 65530

# ES requires at least 262144, or it refuses to start:
$ sudo sysctl -w vm.max_map_count=262144
$ echo "vm.max_map_count = 262144" | sudo tee -a /etc/sysctl.d/99-elasticsearch.conf
```

**5. Reading live memory pressure directly from `/proc/meminfo` (what `free` parses)**
```bash
$ grep -E 'MemTotal|MemAvailable|SwapFree|SwapTotal' /proc/meminfo
MemTotal:       16340000 kB
MemAvailable:    1102340 kB
SwapTotal:       2097148 kB
SwapFree:         102340 kB
```
`MemAvailable` low relative to `MemTotal`, and `SwapFree` nearly exhausted — this host is under real memory pressure, worth checking before it triggers OOM kills.

**6. Checking a process's actual effective ulimits vs the shell's `ulimit -a`**
```bash
$ ulimit -a | grep -E 'open files|max user processes'
open files                      (-n) 1024
max user processes              (-u) 7864

# But the actual running daemon (started by systemd, different context) may differ:
$ cat /proc/$(pgrep nginx | head -1)/limits | grep -E 'open files|processes'
Max open files            65536                65536                files
Max processes             7864                 7864                 processes
```

**7. Diagnosing network drops via `/sys/class/net`**
```bash
$ cat /sys/class/net/eth0/statistics/rx_dropped
18422
$ cat /sys/class/net/eth0/statistics/tx_errors
0
$ ethtool -S eth0 | grep -i drop
     rx_queue_0_drops: 18422
```
Non-zero `rx_dropped` climbing over time points to the NIC ring buffer or a CPU/softirq bottleneck, not an application-level bug.

**8. `vm.swappiness` tuning for a latency-sensitive service (e.g., a database host)**
```bash
$ sysctl vm.swappiness
vm.swappiness = 60

$ sudo sysctl -w vm.swappiness=10   # discourage swapping, prefer reclaiming page cache first
$ echo "vm.swappiness = 10" | sudo tee -a /etc/sysctl.d/99-tuning.conf
```

## Practice Questions

1. A Java service running under systemd hits "too many open files" even though `/etc/security/limits.conf` sets `nofile 65536`. Why doesn't that fix it, and what's the correct fix for a systemd-managed service?
2. What's the difference between a soft limit and a hard limit in `ulimit`, and what can an unprivileged process do (and NOT do) to each?
3. Given a running process's PID, how do you find its actual effective open-file-descriptor limit AND its current open-file-descriptor count, using only `/proc`?
4. What does `sysctl -w` change versus editing `/etc/sysctl.d/*.conf`? Why would a value set via `sysctl -w` disappear after a reboot?
5. Elasticsearch refuses to start with a "max virtual memory areas vm.max_map_count is too low" error. What's the fix, and what does this parameter actually control?
6. Explain `vm.swappiness` — what does a low value (e.g., 10) versus the default (60) tell the kernel to prefer, and why might you lower it specifically on a database host?
7. A network-heavy service shows climbing `rx_dropped` counters. Where do you find this metric, and what does it suggest as opposed to an application-level bug?
8. What's the practical difference between reading `/proc/sys/net/ipv4/ip_forward` directly with `cat` versus running `sysctl net.ipv4.ip_forward`? Why do both work?
9. Design a diagnostic one-liner that lists the top N processes by open file descriptor count on a host, to find what's approaching `fs.file-max`.
10. You need to raise `net.core.somaxconn` for a high-throughput listening service. Walk through both the runtime change AND the persistent (survives-reboot) change, and explain why you need both steps.

## Real Interview Questions (Company-Attributed)

- "What is `ulimit`? What's the fix for a 'Too many open files' error in your script?" — asked at *Morgan Stanley*
- "What is the purpose of the `/proc` directory in Linux?" — asked at *Morgan Stanley*
- "How do you set a CPU and memory limit on a Linux machine?" — asked at *Five9*
- "What is meant by CPU throttling?" — asked at *Netcracker*
- "What is a leap second, and how does Linux handle it?" — asked at *Amadeus Labs*

## Interview Key Points

- The `/etc/security/limits.conf` vs systemd `LimitNOFILE=` split is one of the highest-value gotchas in this whole area — PAM-based limits.conf only applies to login sessions, NOT to services started directly by systemd. Missing this is a very common real-world outage cause.
- `/proc/<pid>/limits` is ground truth for what limits actually apply to a running process — always more trustworthy than assuming from shell `ulimit -a` or config files, since the process may have been started in a different context (systemd, cron, container runtime) with different limits applied.
- Soft limit vs hard limit: a process can raise its own soft limit up to the hard limit without privilege; raising the hard limit itself requires root/`CAP_SYS_RESOURCE` — know this distinction precisely.
- `sysctl -w` changes are NOT persistent — always pair a runtime fix with a `/etc/sysctl.d/*.conf` entry (and `sysctl -p` or a reboot) for it to survive; a classic "fixed it but it broke again after redeploy/reboot" interview scenario.
- Know several concrete, commonly-tuned parameters by name and purpose: `net.core.somaxconn`, `vm.max_map_count` (the famous Elasticsearch one), `vm.swappiness`, `net.ipv4.ip_local_port_range`, `fs.file-max` — being able to name real parameters (not just "you can tune the kernel") is the signal interviewers look for.
- `/proc` and `/sys` require zero special tooling — just `cat`/`grep` — which makes them the fastest, most universally-available diagnostic path when specialized tools (`ss`, `lsof`, monitoring agents) aren't installed on a minimal/locked-down host.
- Counting open FDs via `ls /proc/<pid>/fd | wc -l` compared against `/proc/<pid>/limits` is the standard, tool-free way to catch a file-descriptor leak before it takes down a service.
