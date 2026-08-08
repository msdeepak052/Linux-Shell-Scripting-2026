# Filesystem Types: ext4, XFS, Btrfs — When Each Is Used

Which on-disk format you pick determines your scaling limits, snapshot/rollback options, and how painful growing or shrinking a volume will be later.

## Explanation

### The core architectural split
- **ext4** — the traditional Linux filesystem, a journaling filesystem: writes are first logged to a journal, then flushed to their real location, so an unclean shutdown replays the journal instead of running a full fsck. Mature, extremely well-tested, default on Debian/Ubuntu for years. Supports both **growing and shrinking** (`resize2fs`), which XFS cannot do.
- **XFS** — also journaling, but designed from the ground up for high-throughput, large-file, parallel I/O workloads (originally SGI, now RHEL's default). Scales to far larger filesystem sizes (up to 8 EiB in principle) and handles many concurrent writers well due to allocation groups (internal parallelism). **Can only grow (`xfs_growfs`), never shrink** — this trips people up constantly.
- **Btrfs** — a fundamentally different design: **copy-on-write (CoW)**. Every write goes to a new block rather than overwriting in place, which is what enables its headline features: near-instant **snapshots**, built-in **subvolumes** (independently mountable/snapshotable trees within one filesystem), transparent compression, and built-in RAID-like multi-device support (though btrfs's own RAID5/6 is still considered less battle-tested than mdadm). CoW has a real cost: fragmentation and extra overhead on workloads with lots of small random-write updates (databases, VM disk images) unless tuned (`nodatacow` on specific files/subvolumes).

### Journaling vs copy-on-write, in practice
Journaling (ext4/XFS) protects **metadata consistency** after a crash — it doesn't give you point-in-time rollback. CoW (btrfs) gives you actual historical snapshots because old data blocks aren't overwritten until nothing references them — you can `btrfs subvolume snapshot` and instantly have a consistent read-only (or writable) copy of the entire tree as it existed at that moment, with no separate backup step.

### Which one should you actually use? (Decision rule)

| Situation | Use | Why |
|---|---|---|
| General-purpose Linux server, root filesystem, RHEL/CentOS/Rocky default | **XFS** | Battle-tested default, excellent large-file/parallel-write throughput, what most enterprise distros ship |
| You need to **shrink** a volume later, or workload is millions of tiny files (mail spool, package cache) | **ext4** | XFS genuinely cannot shrink; ext4 handles small-file-heavy metadata slightly better in some benchmarks |
| You need instant snapshots, subvolumes, or transparent compression (container image layers, rollback-before-upgrade) | **Btrfs** | Only one of the three with real CoW snapshot semantics built in — this is what SUSE/openSUSE defaults to and what tools like `snapper` rely on |
| Database data directory / VM disk image storage | **XFS** (or ext4) — avoid raw Btrfs CoW unless `nodatacow` is set | CoW fragmentation hurts random-write-heavy workloads unless explicitly disabled per-file |

**Bottom line: default to XFS for general server/enterprise use, drop to ext4 only if you need shrink capability or are on a distro where it's standard, and reach for Btrfs specifically when you need snapshots/subvolumes as a first-class feature.**

## Hands-On Examples

**1. Check what filesystem type is already in use**
```bash
$ df -T
Filesystem     Type  1K-blocks     Used Available Use% Mounted on
/dev/sda2      xfs    51343360 12456780  38886580  25% /
/dev/nvme0n1p1 ext4  524108800 98234112 399541248  20% /data
```

**2. Format a new partition — ext4 vs XFS**
```bash
$ sudo mkfs.ext4 /dev/sdb1
mke2fs 1.46.5 (30-Dec-2021)
Creating filesystem with 13107200 4k blocks and 3276800 inodes
Allocating group tables: done
Writing inode tables: done
Creating journal (65536 blocks): done
Writing superblocks and filesystem accounting information: done

$ sudo mkfs.xfs /dev/sdc1
meta-data=/dev/sdc1              isize=512    agcount=4, agsize=6553600 blks
data     =                       bsize=4096   blocks=26214400, imaxpct=25
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=12800, version=2
```

**3. XFS cannot shrink — the classic gotcha**
```bash
$ sudo xfs_growfs /data
# grows fine, works up to underlying block device size

$ sudo xfs_shrink /data
xfs_shrink: command not found       # doesn't exist — XFS has NO shrink operation, period
```
The only way to "shrink" an XFS filesystem is: back up the data, recreate a smaller filesystem, restore. Always size XFS volumes conservatively or rely on LVM/thin-provisioning if you're unsure of future size.

**4. Growing ext4 after a partition/LV was extended**
```bash
$ sudo resize2fs /dev/mapper/vg_data-lv_app
resize2fs 1.46.5 (30-Dec-2021)
Filesystem at /dev/mapper/vg_data-lv_app is mounted on /app; on-line resizing required
old_desc_blocks = 4, new_desc_blocks = 5
The filesystem on /dev/mapper/vg_data-lv_app is now 26214400 (4k) blocks long.
```

**5. Btrfs subvolumes and instant snapshots**
```bash
$ sudo mkfs.btrfs /dev/sdd1
$ sudo mount /dev/sdd1 /mnt/data
$ sudo btrfs subvolume create /mnt/data/app
Create subvolume '/mnt/data/app'

$ sudo btrfs subvolume snapshot /mnt/data/app /mnt/data/app-snapshot-2026-08-08
Create a snapshot of '/mnt/data/app' in '/mnt/data/app-snapshot-2026-08-08'

$ sudo btrfs subvolume list /mnt/data
ID 256 gen 12 top level 5 path app
ID 257 gen 14 top level 5 path app-snapshot-2026-08-08
```
The snapshot completed instantly regardless of data size — it's metadata pointing at shared CoW blocks, not a byte-for-byte copy.

**6. Real-world scenario: choosing a filesystem for a new database data volume**
```bash
$ lsblk /dev/nvme2n1
nvme2n1  259:5   0  1T  0 disk
$ sudo mkfs.xfs -L pgdata /dev/nvme2n1
$ sudo mkdir -p /var/lib/postgresql/data
$ sudo mount /dev/nvme2n1 /var/lib/postgresql/data
```
XFS chosen deliberately here: high concurrent I/O from many Postgres backend processes benefits from XFS's allocation-group parallelism, and this volume is expected to only ever grow, never shrink.

## Practice Questions

1. A teammate provisions a 500GB XFS volume for logs, then later needs to shrink it to 200GB to reclaim space for another volume. What do they need to do, and why can't `xfs_growfs` help here?
2. Explain the practical difference between journaling (ext4/XFS) and copy-on-write (Btrfs) in terms of what protection each actually gives you after a crash.
3. Why might Btrfs be a worse choice for a MySQL/Postgres data directory unless specifically tuned, and what tuning would you apply?
4. You're setting up snapshot-based rollback before a risky in-place OS upgrade. Which filesystem makes this trivial, and what command creates the snapshot?
5. What's the maximum filesystem size difference between ext4 and XFS, and when would that actually matter in practice?
6. A server has millions of small files (a mail spool). Which filesystem characteristics would you weigh when choosing ext4 vs XFS here?
7. How do you check which filesystem type is already in use on a mounted volume without unmounting it?
8. Describe the full ext4 resize command chain needed after extending an underlying LVM logical volume, and contrast with the equivalent XFS command.
9. Why is "just switch the filesystem type" never a live/in-place operation — what does actually changing filesystem type require?

## Interview Key Points

- **XFS can never shrink, only grow** — this is the #1 "gotcha" fact interviewers check; ext4 can do both via `resize2fs`.
- Journaling filesystems (ext4, XFS) protect **metadata integrity** across crashes; they are not a substitute for real backups or point-in-time recovery.
- Btrfs's copy-on-write is what makes instant snapshots possible — know this mechanism, not just the feature name.
- CoW has a real cost on random-write-heavy workloads (databases, VM images) — mention `nodatacow`/tuning as the senior-level nuance, not "just avoid Btrfs."
- Changing a filesystem type is **never in-place** — it always means backup → reformat → restore, regardless of which two types are involved.
- XFS is the modern RHEL/enterprise default; ext4 remains extremely common and safe; Btrfs is the deliberate choice when snapshots/subvolumes/compression are first-class requirements (SUSE default).
- `resize2fs` (ext4) vs `xfs_growfs` (XFS) — know both command names cold, they come up in almost every "extend a volume" scenario question.
