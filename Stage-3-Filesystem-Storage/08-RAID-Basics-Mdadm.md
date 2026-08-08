# RAID Basics: `mdadm`, RAID Levels 0/1/5/6/10

Software RAID via `mdadm` combines multiple block devices into a single redundant/performant array — knowing which level trades off capacity, performance, and fault tolerance which way is a core sysadmin fundamental.

## Explanation

**RAID levels — the tradeoffs**:
- **RAID 0 (striping)**: data split evenly across N disks, no redundancy. Best performance and full capacity (N × disk size), but **any single disk failure loses all data**. Use only for disposable/scratch/cache workloads where speed matters and data loss is acceptable.
- **RAID 1 (mirroring)**: every disk is an exact copy of every other. Usable capacity = size of one disk (regardless of N). Tolerates failure of all-but-one disk. Read performance can improve (reads spread across mirrors), write performance ≈ single disk. Simple and very robust; expensive in raw capacity.
- **RAID 5 (striping + single distributed parity)**: data and parity striped across N disks; usable capacity = (N-1) × disk size. Tolerates **exactly 1** disk failure. Popular historically, but has a well-known danger: during a rebuild after a failed disk, the remaining disks are under heavy read stress, and a **second failure (or an unrecoverable read error) during rebuild loses the whole array** — increasingly risky as disk sizes grow (rebuild windows can be many hours to days on large drives).
- **RAID 6 (striping + double distributed parity)**: like RAID 5 but with two parity blocks; usable capacity = (N-2) × disk size. Tolerates **2 simultaneous disk failures**. The safer modern choice over RAID 5 for large-capacity arrays, at the cost of extra parity overhead and slower writes (double parity computation).
- **RAID 10 (1+0, striped mirrors)**: pairs of mirrored disks (RAID 1) then striped together (RAID 0). Usable capacity = N/2 × disk size (minimum 4 disks). Excellent performance (approaches RAID 0) AND good redundancy (survives multiple failures as long as no mirrored pair loses both members). The preferred choice for performance-critical + redundancy-critical workloads (databases) when disk cost isn't the primary constraint.

**Quick decision table**:
| Level | Min disks | Usable capacity | Fault tolerance | Typical use |
|---|---|---|---|---|
| 0 | 2 | 100% | none | scratch/cache, no critical data |
| 1 | 2 | 50% (1 disk) | N-1 disks | OS/boot mirrors, small critical volumes |
| 5 | 3 | (N-1)/N | 1 disk | general purpose, aging choice for big disks |
| 6 | 4 | (N-2)/N | 2 disks | large-capacity arrays, safer than 5 |
| 10 | 4 | 50% | depends on layout, survives most single+ failures | databases, high-IOPS workloads |

**`mdadm` — core commands**:
```
mdadm --create /dev/md0 --level=1 --raid-devices=2 /dev/sdb1 /dev/sdc1     # create a mirror
mdadm --detail /dev/md0                                                     # full array status
cat /proc/mdstat                                                            # quick kernel-level array status
mdadm --detail --scan >> /etc/mdadm/mdadm.conf                              # persist array definition
mdadm --add /dev/md0 /dev/sdd1                                              # add a spare/replacement disk
mdadm --fail /dev/md0 /dev/sdb1 && mdadm --remove /dev/md0 /dev/sdb1        # mark a disk failed, remove it
mdadm --stop /dev/md0                                                       # stop (deactivate) an array
mdadm --assemble --scan                                                     # reassemble arrays at boot (usually automatic via initramfs/udev)
```

**Gotchas / important nuances**:
- RAID is **not a backup** — it protects against disk hardware failure only, not against accidental deletion, corruption, ransomware, or filesystem bugs. Say this explicitly in interviews; it's a very common trap question.
- RAID 5's "write hole" and rebuild-time vulnerability is why RAID 6 or RAID 10 is generally preferred for anything beyond small arrays today, especially with multi-TB disks (long rebuild windows).
- After `mdadm --create`, the array must be **persisted** in `/etc/mdadm/mdadm.conf` (Debian/Ubuntu) or `/etc/mdadm.conf` (RHEL-family), otherwise it may not reassemble correctly on reboot.
- A degraded array (one disk down on RAID 5, or one down on RAID 1) still functions but has **zero further fault tolerance** — replace the failed disk immediately; don't treat "still working" as "fine."
- `mdadm` is **software** RAID handled by the kernel; hardware RAID controllers (with their own BBU cache, `MegaCli`/`storcli` tooling) are a separate world with different management commands — know the distinction exists even if not asked to operate one.
- Rebuild time and I/O impact should be understood: an active rebuild competes for disk I/O with production traffic; on RAID 5/6 this can meaningfully degrade application latency for hours.

## Hands-On Examples

**1. Creating a RAID 1 mirror**
```bash
$ mdadm --create /dev/md0 --level=1 --raid-devices=2 /dev/sdb1 /dev/sdc1
mdadm: Note: this array has metadata at the start and
    may not be suitable as a boot device.
mdadm: Defaulting to version 1.2 metadata
mdadm: array /dev/md0 started.
```

**2. Checking array status**
```bash
$ cat /proc/mdstat
Personalities : [raid1]
md0 : active raid1 sdc1[1] sdb1[0]
      10476544 blocks super 1.2 [2/2] [UU]
      [=====>...............]  resync = 25.3% (2653184/10476544) finish=2.1min speed=61000K/sec

$ mdadm --detail /dev/md0
/dev/md0:
           Version : 1.2
     Creation Time : Sat Aug  8 10:15:02 2026
        Raid Level : raid1
        Array Size : 10476544 (9.99 GiB 10.73 GB)
     Used Dev Size : 10476544 (9.99 GiB 10.73 GB)
      Raid Devices : 2
     Total Devices : 2
               State : clean, resyncing
      Active Devices : 2
    Working Devices : 2
     Failed Devices : 0
      Spare Devices : 0
              Layout : -
          Chunk Size : -
                Name : server1:0
                UUID : 3f8a1234:5b6c7890:9d0e1f2a:3b4c5d6e
              Events : 17
    Number   Major   Minor   RaidDevice State
       0       8       17        0      active sync   /dev/sdb1
       1       8       33        1      active sync   /dev/sdc1
```

**3. Creating filesystem and persisting the array config**
```bash
$ mkfs.ext4 /dev/md0
$ mkdir -p /data
$ mount /dev/md0 /data
$ mdadm --detail --scan | tee -a /etc/mdadm/mdadm.conf
ARRAY /dev/md0 metadata=1.2 name=server1:0 UUID=3f8a1234:5b6c7890:9d0e1f2a:3b4c5d6e
$ update-initramfs -u          # Debian/Ubuntu: rebuild initramfs so array assembles at boot
```

**4. Creating a RAID 5 array from 4 disks**
```bash
$ mdadm --create /dev/md1 --level=5 --raid-devices=4 /dev/sdd1 /dev/sde1 /dev/sdf1 /dev/sdg1
mdadm: array /dev/md1 started.
$ mdadm --detail /dev/md1 | grep -E "Array Size|Raid Level|State"
     Raid Level : raid5
       Array Size : 31428096 (29.97 GiB)   # (4-1) x ~10G disks = ~30G usable
             State : clean, degraded, resyncing
```

**5. Simulating and handling a disk failure on RAID 1**
```bash
$ mdadm --fail /dev/md0 /dev/sdb1
mdadm: set /dev/sdb1 faulty in /dev/md0

$ cat /proc/mdstat
md0 : active raid1 sdc1[1] sdb1[0](F)
      10476544 blocks super 1.2 [2/1] [_U]     # degraded — only 1 of 2 disks active

$ mdadm --remove /dev/md0 /dev/sdb1
mdadm: hot removed /dev/sdb1 from /dev/md0

# replace the physical disk, partition it, then re-add
$ mdadm --add /dev/md0 /dev/sdb1
mdadm: added /dev/sdb1

$ cat /proc/mdstat
md0 : active raid1 sdc1[1] sdb1[2]
      10476544 blocks super 1.2 [2/1] [_U]
      [====>...............]  recovery = 22.0% (2305536/10476544) finish=1.8min speed=58000K/sec
```

**6. RAID 6 for larger, safer arrays**
```bash
$ mdadm --create /dev/md2 --level=6 --raid-devices=6 /dev/sd{h,i,j,k,l,m}1
mdadm: array /dev/md2 started.
$ mdadm --detail /dev/md2 | grep -E "Raid Level|Array Size"
     Raid Level : raid6
       Array Size : 41961472 (40.02 GiB)   # (6-2) x ~10G disks = ~40G usable, tolerates 2 disk failures
```

**7. RAID 10 for a performance + redundancy database volume**
```bash
$ mdadm --create /dev/md3 --level=10 --raid-devices=4 /dev/sd{n,o,p,q}1
mdadm: array /dev/md3 started.
$ mdadm --detail /dev/md3 | grep -E "Raid Level|Array Size|Layout"
     Raid Level : raid10
       Array Size : 20971520 (20.00 GiB)    # 4 x 10G disks / 2 = 20G usable
             Layout : near=2
```

**8. Monitoring RAID health long-term (cron/monit style check)**
```bash
$ cat /proc/mdstat | grep -E "^md|blocks"
md0 : active raid1 sdc1[1] sdb1[0]
      10476544 blocks super 1.2 [2/2] [UU]      # [UU] = both disks up; a "_" means a disk is down/missing
md2 : active raid6 sdh1[0] sdi1[1] sdj1[2] sdk1[3] sdl1[4] sdm1[5]
      41961472 blocks super 1.2 level 6, 512k chunk, algorithm 2 [6/6] [UUUUUU]

# mdadm --monitor can be run as a daemon to email alerts on state changes:
$ mdadm --monitor --scan --daemonise --mail=ops@company.com
```

## Practice Questions

1. Explain the capacity and fault-tolerance tradeoffs of RAID 0, 1, 5, 6, and 10 — for each, how many disks can fail before data loss, and what's the usable capacity formula?
2. Why is RAID 5 increasingly discouraged for large modern disks, and what specifically happens during a "risky rebuild window"?
3. You have 6 identical 4TB disks and need maximum performance with the ability to survive at least one disk failure, and capacity is a secondary concern. Which RAID level do you choose, and why?
4. Walk through the exact `mdadm` commands to simulate a failed disk in a RAID 1 array, remove it, and re-add a replacement.
5. Why is "RAID is not a backup" such a commonly emphasized point in interviews? Give two failure scenarios where RAID provides zero protection.
6. What's the difference between `cat /proc/mdstat` and `mdadm --detail /dev/mdX`? When would you use each?
7. After `mdadm --create`, what step is required to ensure the array reassembles correctly after a reboot, and what file does it typically go into on Debian/Ubuntu vs RHEL-family systems?
8. What does a degraded array mean operationally, and why is "the array still works" not a reason to delay replacing the failed disk?
9. Compare RAID 6 and RAID 10 for a 6-disk array in terms of usable capacity and fault tolerance. Which would you pick for a write-heavy database workload, and why?
10. What's the difference between software RAID (`mdadm`) and hardware RAID (a dedicated RAID controller)? Name one operational difference in how you'd manage/monitor each.

## Interview Key Points

- **Memorize the capacity/tolerance table** for RAID 0/1/5/6/10 — this is asked constantly, often as a rapid-fire "what's the usable capacity of N disks in RAID X" question.
- **"RAID is not a backup"** — say this proactively; RAID protects only against disk hardware failure, not deletion, corruption, ransomware, or filesystem-level bugs. A classic trap when candidates conflate redundancy with backup.
- RAID 5's rebuild-time vulnerability (a second failure or unrecoverable read error during rebuild = total data loss) is why **RAID 6 or RAID 10 is the modern recommendation** for anything beyond small/low-value arrays, especially as disk sizes (and thus rebuild times) grow.
- RAID 10 is the standard answer for "best of both" (performance near RAID 0, redundancy like RAID 1) — the tradeoff is you only get 50% usable capacity and need a minimum of 4 disks.
- Know `cat /proc/mdstat` (quick kernel status, `[UU]` vs `[U_]` for healthy vs degraded) versus `mdadm --detail /dev/mdX` (full verbose per-array detail) — both are commonly demonstrated live.
- Persisting the array via `mdadm --detail --scan >> /etc/mdadm/mdadm.conf` (or RHEL equivalent) plus an initramfs rebuild is a step candidates often forget — mention it explicitly.
- A **degraded array has zero remaining fault tolerance** — emphasize that "still working" after one disk failure on RAID 5 is not "fine," it's a ticking clock until the replacement is in and rebuilt.
- Software RAID (`mdadm`, kernel-managed) vs hardware RAID (dedicated controller with battery-backed cache, `MegaCli`/`storcli`/`perccli` tooling) — know they're different management stacks even if you're mainly asked about `mdadm`.
