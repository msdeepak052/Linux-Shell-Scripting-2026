# Performance Baselining: `vmstat`, `iostat`, `sar`, `dstat`

You can't tell a system is "slow" without knowing what "normal" looked like — baselining with these tools, both live and historically, is what turns "it feels slow" into a specific, provable bottleneck.

## Explanation

**`vmstat`** — system-wide snapshot of processes, memory, swap, I/O, and CPU in one compact table. `vmstat 1` repeats every second; the **first line is a boot-time average, always discard it**.
- `r` — processes waiting for CPU (runnable queue); sustained `r` > core count = CPU-bound contention.
- `b` — processes blocked in uninterruptible sleep (usually I/O wait).
- `si`/`so` — swap in/out; any sustained non-zero value here is a red flag (active swapping under load).
- `wa` (in `vmstat`'s CPU section, or via `top`) — % time CPU idle while waiting on I/O; high `wa` with low `us`/`sy` points at storage as the bottleneck, not compute.
- `free`/`buff`/`cache` — raw memory breakdown; low `free` alone is NOT a problem (Linux uses spare RAM as page cache aggressively) — check `available` (via `free -h`) instead.

**`iostat`** — per-device disk I/O statistics (part of `sysstat` package). `iostat -x 1` for the extended, most-useful view, repeated every second.
- `%util` — percentage of time the device was busy servicing requests; near 100% sustained = device saturated (though for SSD/NVMe with parallel queues, `%util` can mislead — cross-check `avgqu-sz`/`aqu-sz`).
- `await` — average time (ms) for I/O requests to complete, including queue wait; the single best "is storage slow" metric.
- `r/s`, `w/s` — reads/writes per second (IOPS).
- `rkB/s`, `wkB/s` — throughput.
- `avgqu-sz` (older) / `aqu-sz` (newer sysstat) — average queue depth; a growing queue with rising `await` = the device can't keep up with the request rate.

**`sar`** (System Activity Reporter, also `sysstat`) — the tool for **historical** data, not just live snapshots, because it's normally run continuously via cron/systemd timer and logs to `/var/log/sa/`.
- `sar -u 1 5` — live CPU stats, 5 samples 1 second apart (same shape as `vmstat`/`mpstat` for CPU).
- `sar -r` — memory.
- `sar -d -p` — disk, with human-readable device names (`-p`).
- `sar -n DEV 1` — network throughput per interface.
- `sar -f /var/log/sa/sa08` — replay a **specific past day's** data (file named `saDD`) — this historical capability is `sar`'s defining advantage: "what did CPU look like at 3 AM last Tuesday when the incident happened" is answerable ONLY if `sar` was already collecting, which is why it's typically enabled by default/cron on production hosts.

**`dstat`** — a more modern, colorized, pluggable combination of `vmstat`+`iostat`+`ifstat`+more in one live view (may not be installed by default; increasingly superseded by `dool` on newer distros as a maintained fork). Good for live human-readable dashboards, less common as an *automation* data source than `sar`.
```bash
dstat -cdngy 1    # cpu, disk, network, page-faults, system, every 1s
```

**Baselining methodology**: capture these metrics during known-healthy periods (via `sar`'s continuous collection, or your own cron'd snapshots) so an incident can be compared against a real baseline rather than gut feel — "CPU is at 40%" means nothing without knowing that this workload normally runs at 8%.

## Hands-On Examples

**1. `vmstat` — spotting CPU contention vs I/O wait at a glance**
```bash
$ vmstat 1 5
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
 9  2      0 812340  20120 3021440    0    0    12    88 2044 5122 78 14  2  6  0
 8  3      0 801220  20120 3022100    0    0     8    64 2011 5088 81 12  1  6  0
```
`r=8-9` on a 8-core box (contention right at/above core count) with `wa` low (~6%) — this is CPU-bound, not storage-bound.

**2. `vmstat` — spotting active swapping (a serious red flag)**
```bash
$ vmstat 1 3
procs -----------memory---------- ---swap-- -----io----
 r  b   swpd   free   buff  cache   si   so    bi    bo
 3  4  204800  50120  10240  600000  842  910   200   180
```
`si`/`so` (swap in/out) both non-zero and climbing — the system is actively thrashing swap under memory pressure, which will make everything feel slow regardless of CPU numbers.

**3. `iostat -x` — confirming a slow disk as the bottleneck**
```bash
$ iostat -x 1 3
Device            r/s     w/s   rkB/s   wkB/s  await  aqu-sz  %util
nvme0n1          12.00  340.00   480.0  42000.0  48.20    6.80  97.50
```
`await` of 48ms (should be low single digits for NVMe) plus `%util` near 100% and a real queue depth (`aqu-sz` 6.8) confirms the disk itself is saturated and the bottleneck.

**4. `iostat` — comparing two devices to find which one is actually hot**
```bash
$ iostat -x 1 1
Device      r/s    w/s   await  %util
sda         2.00   1.00   3.10   4.00
sdb        45.00 380.00  62.40  99.80
```
`sdb` (likely the DB data volume) is saturated; `sda` (likely the OS/root disk) is nearly idle — narrows the investigation to whatever workload lives on `sdb`.

**5. `sar` — replaying historical CPU data from an overnight incident**
```bash
$ ls /var/log/sa/
sa06  sa07  sa08

$ sar -u -f /var/log/sa/sa08 -s 03:00:00 -e 03:30:00
Linux 5.15.0 (host01)  08/08/2026

03:00:01     CPU     %user   %system   %iowait    %idle
03:10:01     all      12.40      3.10      68.90     15.60
03:20:01     all      14.10      2.90      70.20     12.80
```
`%iowait` around 70% during the incident window — proves the slowness was storage-bound, not CPU-bound, hours after the fact, purely from data `sar` had already been collecting.

**6. `sar -n DEV` — network throughput baseline vs an incident spike**
```bash
$ sar -n DEV 1 3
IFACE   rxpck/s  txpck/s  rxkB/s   txkB/s
eth0     8200.00  7100.00  9800.20  8400.10
```
Compare against a stored baseline (e.g., normal is ~2000 rxpck/s) to confirm an actual traffic spike rather than assuming.

**7. `dstat` — one combined live view during active troubleshooting**
```bash
$ dstat -cdngy 1 5
----total-cpu-usage---- -dsk/total- -net/total- ---paging-- ---system--
usr sys idl wai stl| read  writ| recv  send|  in   out | int   csw
 82  11   4   3   0|   0   420k|  12k   45k|   0     0 |2044  5122
 79  13   5   3   0|   0   380k|  11k   42k|   0     0 |2011  5088
```
One screen confirms CPU-bound (usr high, wai low) while disk/network stay modest — fast triage without juggling three separate tools.

**8. Setting up continuous `sar` collection for future baselining (if not already enabled)**
```bash
$ cat /etc/cron.d/sysstat
# sysstat cron jobs, collects every 10 minutes by default
*/10 * * * * root /usr/lib/sysstat/sa1 1 1
53 23 * * * root /usr/lib/sysstat/sa2 -A

$ sudo systemctl enable --now sysstat
$ sar -u 1 3    # confirm live collection works
```

## Practice Questions

1. In `vmstat` output, the `r` column shows 12 sustained on a 4-core box. What does this indicate, and what would you check next to confirm CPU contention specifically?
2. Explain why low `free` memory in `vmstat`/`free -h` output is often NOT a problem by itself. What column should you actually look at, and why?
3. What's the difference between `si`/`so` (swap in/out) in `vmstat` versus `swpd` (total swap used)? Why is non-zero `si`/`so` a more urgent signal than non-zero `swpd` alone?
4. Given `iostat -x` output showing `%util` at 98% but `await` at only 2ms, is the disk actually a bottleneck? Explain why `%util` can be misleading on modern NVMe/SSD devices with parallel queues.
5. An incident happened at 3 AM last night and nobody was watching a live dashboard. How would you retroactively determine whether it was CPU-bound or I/O-bound, and what tool/setup makes this possible after the fact?
6. Two disks, `sda` and `sdb`, are attached to a host. `iostat -x` shows `sdb` with `await=60ms` and `sda` with `await=2ms`. How does this help you scope a slow-database investigation?
7. Why is `sar` uniquely suited for historical baselining compared to `vmstat`/`iostat`/`dstat`, given all four can technically show similar live metrics?
8. Write the `sar` command to replay CPU statistics from a specific past day's log file, filtered to a 30-minute window around a known incident time.
9. What's the practical advantage of `dstat` (or its maintained fork `dool`) over running `vmstat`, `iostat`, and a network stats tool in three separate terminals during live troubleshooting?
10. Design a baselining approach for a new production host: what would you capture, on what cadence, and why does having this baseline matter when an incident occurs weeks later?

## Real Interview Questions (Company-Attributed)

- "What's the best command to monitor disk read/write activity?" — asked at *Alphadyne*
- "How do you monitor overall system performance?" — asked at *Synechron*
- "Explain the use of `iftop`." — asked at *Sigmoid* (part of a rapid-fire "explain these Linux commands" interview round)

## Interview Key Points

- Always discard `vmstat`'s first output line — it's a since-boot average, not a live sample, and quoting it as "current" is a common mistake that undermines credibility in an answer.
- `wa`/`%iowait` high with `us`/`sy` low is the specific signature of an I/O-bound (not CPU-bound) system — know this distinction cold, it's one of the most frequently tested "read this output and diagnose it" questions.
- `await` (not `%util` alone) is the most reliable single indicator of disk trouble on modern SSD/NVMe devices — `%util` can read near 100% on a healthy, heavily-parallel NVMe device that's actually keeping up fine; know to cross-check queue depth (`aqu-sz`) and `await` together.
- `sar`'s defining advantage over `vmstat`/`iostat`/`dstat` is **historical replay** — it's normally running continuously via cron/systemd (the `sysstat` package), logging to `/var/log/sa/saDD`, making "what was happening at the exact time of the incident" answerable after the fact. This is a strong, specific answer to "how do you investigate an overnight incident you weren't watching live."
- Swap **activity** (`si`/`so` non-zero and moving) is a far more urgent signal than swap **usage** (`swpd` > 0) — some swap being used at rest is normal; active swapping under load is not.
- Being able to read a `vmstat`/`iostat` table cold and state the bottleneck class (CPU-bound / memory-pressure / I/O-bound / network-bound) from the numbers alone is exactly the skill interviewers are testing with "here's some output, what's wrong" style questions — practice narrating the columns out loud.
- Comparing live numbers against a known-healthy baseline (not absolute thresholds) is the maturity signal — "CPU at 40%" is meaningless without knowing the workload's normal operating range, which is the whole justification for baselining in the first place.
