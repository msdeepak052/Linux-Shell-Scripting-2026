# Swap: Creating/Enabling Swap, `swapon`/`swapoff`, `vm.swappiness`

Swap extends available memory onto disk as a safety valve against OOM kills, but how much the kernel actually uses it — and how you provision it — has real production performance implications.

## Explanation

**What swap is**: disk space (a dedicated partition or a swapfile) the kernel uses to page out memory pages that aren't actively being used, freeing physical RAM for active workloads. It is NOT a substitute for RAM (disk is orders of magnitude slower), but a pressure-relief mechanism that avoids the OOM killer firing prematurely, and lets the kernel evict cold/idle pages (e.g., an idle background process's memory) in favor of active page cache.

**Two ways to provision swap**:
- **Swap partition**: a dedicated partition with type/flag set, formatted with `mkswap`. Slightly more traditional, fixed size.
- **Swapfile**: a regular file on an existing filesystem, formatted with `mkswap`. More flexible (resize by making a new file), the common modern default (cloud images, containers-on-VMs), works on any filesystem that supports it (ext4, XFS — NOT on Btrfs without special handling, historically not supported on tmpfs).

**Creating and enabling a swapfile**:
```bash
fallocate -l 4G /swapfile        # fast allocation (or dd if=/dev/zero of=/swapfile bs=1M count=4096 on older kernels/fs that don't support fallocate for swap, e.g. some Btrfs setups)
chmod 600 /swapfile              # must not be world-readable — contains memory contents
mkswap /swapfile                 # write swap signature
swapon /swapfile                 # activate immediately
```
Persist across reboot by adding to `/etc/fstab`:
```
/swapfile none swap sw 0 0
```

**Managing active swap**:
```
swapon -s          # legacy: show active swap summary
swapon --show       # modern: show active swap devices/files, in a table
swapoff /swapfile    # deactivate — kernel migrates any pages currently in that swap back to RAM first
free -h              # quick view of total/used/free RAM and swap
cat /proc/swaps       # raw kernel view of active swap areas
```
**Important**: `swapoff` requires enough free RAM to hold everything currently swapped out — on a memory-pressured system, `swapoff` itself can trigger OOM behavior or hang if there isn't room.

**`vm.swappiness`** — a kernel tunable (0-100) controlling how aggressively the kernel swaps out anonymous memory pages **before** RAM is technically full, in favor of keeping filesystem page cache:
- `0` — avoid swapping unless truly necessary (near-OOM); prioritize keeping processes fully in RAM.
- `60` — the traditional Linux default; moderate willingness to swap.
- `100` — swap aggressively, favor page cache aggressively over anonymous memory.
- Databases (PostgreSQL, MySQL, Redis) commonly recommend low swappiness (`1`-`10`) to avoid unpredictable latency spikes from swapping hot data pages, while general-purpose/desktop systems tolerate the default.

```
cat /proc/sys/vm/swappiness          # check current value
sysctl vm.swappiness                 # same, via sysctl
sysctl vm.swappiness=10              # change live (not persistent across reboot)
echo 'vm.swappiness=10' >> /etc/sysctl.conf   # persist
sysctl -p                             # reload sysctl.conf
```

**Gotchas**:
- Swap on a swapfile located on a **compressed or copy-on-write filesystem (Btrfs)** needs special handling (`chattr +C`, `btrfs filesystem mkswapfile`, or use a dedicated partition) — plain `mkswap` on a Btrfs file can fail or corrupt.
- Cloud/VM images increasingly ship with **zero swap by default** (relying on OOM killer + autoscaling instead) — always check `free -h` on a fresh box, don't assume swap exists.
- High swap **usage** isn't automatically bad; consistently high swap **I/O** (`si`/`so` columns in `vmstat`) causing latency is the real problem to watch for.
- Swap doesn't fix a genuine memory leak — it just delays the OOM kill while thrashing performance in the meantime.

## Hands-On Examples

**1. Checking current swap state**
```bash
$ free -h
               total        used        free      shared  buff/cache   available
Mem:            15Gi       9.2Gi       1.1Gi       340Mi       5.3Gi       5.8Gi
Swap:             0B          0B          0B

$ swapon --show
# empty — no swap configured at all
```

**2. Creating and activating a 4G swapfile**
```bash
$ fallocate -l 4G /swapfile
$ ls -lh /swapfile
-rw-r--r-- 1 root root 4.0G Aug  8 10:00 /swapfile

$ chmod 600 /swapfile
$ mkswap /swapfile
Setting up swapspace version 1, size = 4 GiB (4294963200 bytes)
no label, UUID=8f3c1a2e-1234-4abc-9def-abcdef123456

$ swapon /swapfile
$ swapon --show
NAME       TYPE SIZE USED PRIO
/swapfile  file   4G   0B   -2
```

**3. Persisting across reboot**
```bash
$ echo '/swapfile none swap sw 0 0' >> /etc/fstab
$ mount -a          # dry-run validate fstab entries didn't break
$ cat /etc/fstab | grep swap
/swapfile none swap sw 0 0
```

**4. Confirming with `free` and `/proc/swaps`**
```bash
$ free -h
               total        used        free      shared  buff/cache   available
Mem:            15Gi       9.2Gi       1.1Gi       340Mi       5.3Gi       5.8Gi
Swap:           4.0Gi          0B       4.0Gi

$ cat /proc/swaps
Filename                                Type            Size            Used            Priority
/swapfile                               file            4194300         0               -2
```

**5. Safely deactivating swap (e.g., before removing/resizing the swapfile)**
```bash
$ swapon --show
NAME       TYPE SIZE  USED PRIO
/swapfile  file   4G  1.2G   -2

$ free -h | grep Mem
Mem:            15Gi        11Gi       800Mi

$ swapoff /swapfile          # kernel pages the 1.2G back into RAM first — verify enough free RAM exists
$ swapon --show               # empty, confirms it's off
$ rm /swapfile
$ fallocate -l 8G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
```

**6. Checking and tuning `vm.swappiness`**
```bash
$ sysctl vm.swappiness
vm.swappiness = 60

$ sysctl vm.swappiness=10        # live change, e.g. on a DB server to reduce swap eagerness
vm.swappiness = 10

$ echo 'vm.swappiness=10' | tee -a /etc/sysctl.conf
$ sysctl -p
vm.swappiness = 10
```

**7. Diagnosing swap thrashing in real time**
```bash
$ vmstat 2 5
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
 2  3  850000  98000  12000 780000 1200 3400   500  2100 4500 8900 30 25 10 35  0
 3  4  920000  75000  11500 760000 1800 4100   600  2500 4700 9200 28 30  5 37  0
# si/so (swap in/out) consistently high with wa (I/O wait) climbing = active thrashing, RAM is the real fix
```

**8. Setting up a swap partition instead of a swapfile**
```bash
$ lsblk
NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINT
sdb      8:16   0    8G  0 disk
└─sdb1   8:17   0    8G  0 part

$ mkswap /dev/sdb1
Setting up swapspace version 1, size = 8 GiB
$ swapon /dev/sdb1
$ echo 'UUID=$(blkid -s UUID -o value /dev/sdb1) none swap sw 0 0' >> /etc/fstab
$ swapon --show
NAME       TYPE      SIZE USED PRIO
/dev/sdb1  partition    8G   0B   -2
```

## Practice Questions

1. Walk through the exact commands to create, secure-permission, activate, and persist a 4G swapfile across reboots.
2. Why must a swapfile have `chmod 600` permissions before `mkswap`? What's the security risk if it doesn't?
3. What does `vm.swappiness` actually control, and why would you set it lower (e.g., `10`) on a database server versus leaving the default `60`?
4. Is high swap *usage* automatically a problem? What metric would you actually look at (and in what tool) to determine if swap is hurting performance?
5. You run `swapoff /swapfile` on a system under memory pressure and it hangs. Why does this happen, and what should you check before running `swapoff` in that situation?
6. What's the difference in setup between a swap partition and a swapfile, and which would you choose on a cloud VM with a single resizable root disk?
7. A fresh cloud VM shows `Swap: 0B` in `free -h`. Is this a misconfiguration or expected? What's the tradeoff of not having swap at all versus having some?
8. Explain why swap doesn't "fix" a genuine memory leak in an application — what actually happens over time if you just keep adding more swap to compensate?
9. What special consideration applies to creating a swapfile on a Btrfs filesystem compared to ext4/XFS?
10. Given `vmstat 2 5` output showing rising `si`/`so` and `wa` columns, how do you interpret it, and what's your remediation path (short-term vs actual fix)?

## Interview Key Points

- Swap is a **pressure-relief valve, not extra RAM** — disk I/O latency makes heavy swap usage a performance problem, not a capacity solution; always frame it this way.
- Know the full swapfile workflow cold: `fallocate`/`dd` → `chmod 600` → `mkswap` → `swapon` → persist via `/etc/fstab`.
- `chmod 600` before `mkswap` matters because the swapfile can contain sensitive memory contents (credentials, keys) paged out from any process — a readable swapfile is a real security hole.
- **`vm.swappiness` (0-100)** is a very commonly asked tunable: lower = prefer keeping processes in RAM, avoid swapping until necessary (recommended for databases/latency-sensitive workloads); higher = swap more eagerly to preserve page cache. Default is `60`.
- `sysctl vm.swappiness=N` is a live, non-persistent change — persisting requires editing `/etc/sysctl.conf` (or a file under `/etc/sysctl.d/`) and reloading with `sysctl -p`.
- `swapoff` needs enough free RAM to reabsorb whatever's currently swapped out — can hang or fail under memory pressure; this is a real operational gotcha worth naming proactively.
- Diagnosing swap-caused performance problems uses `vmstat` (`si`/`so` columns for swap in/out rate) alongside `free -h`, not just checking whether swap is "used" — used swap alone isn't inherently bad, active thrashing is.
- Cloud-native/container-oriented images frequently ship with **no swap by default**, relying on the OOM killer and autoscaling/right-sizing instead — know this is a deliberate modern design choice, not an oversight.
