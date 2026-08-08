# Disk & Partition Basics: `lsblk`, `fdisk`, `parted`

Before any filesystem or LVM setup can happen, you need to see and manipulate the raw block devices and their partition tables — this is where every storage task starts.

## Explanation

### Block devices, partitions, and partition tables
The kernel exposes each physical/virtual disk as a block device node under `/dev` — `/dev/sda`, `/dev/nvme0n1`, `/dev/vda`, etc. A disk itself isn't directly usable for a filesystem in most setups; it's divided into **partitions** (`/dev/sda1`, `/dev/sda2`, `/dev/nvme0n1p1`) via a **partition table** written to the start of the disk. Two partition table formats matter today:
- **MBR (Master Boot Record)** — legacy, 32-bit sector addressing → **2TiB disk size limit**, max 4 primary partitions (or 3 primary + 1 extended holding logical partitions).
- **GPT (GUID Partition Table)** — modern standard, supports disks far larger than 2TiB, up to 128 partitions by default, stores a backup copy of the table at the end of the disk (self-healing against corruption at the start).

### The three tools and what each is actually for
- **`lsblk`** — read-only. Lists block devices as a tree (disks → partitions → LVM/filesystem layer on top), showing size, mountpoint, filesystem type (`lsblk -f`). This is your **first command** on any storage question — it orients you before touching anything.
- **`fdisk`** — interactive, menu-driven partition editor. Historically MBR-only, but modern `fdisk` (util-linux ≥ 2.23) fully supports GPT too. Simple, ubiquitous, safe (nothing is written to disk until you explicitly type `w`).
- **`parted`** — more powerful, supports both interactive and **non-interactive scripted mode** (`parted -s ...`), understands GPT natively from the start, and can resize partitions (not filesystems — that's a separate step with `resize2fs`/`xfs_growfs`). Preferred for automation (Ansible playbooks, provisioning scripts) because of `-s`/`--script`.

Also worth knowing: `blkid` prints UUID/LABEL/filesystem type per device (used to populate `/etc/fstab`), and `partprobe` (or `partx -a`) forces the kernel to re-read a disk's partition table after you change it without rebooting — critical on a live server where you can't just reboot to pick up a new partition.

### Which one should you actually use? (Decision rule)

| Situation | Use | Why |
|---|---|---|
| Just inspecting what's attached, sizes, mountpoints | **`lsblk`** (add `-f` for filesystem/UUID) | Read-only, fast, tree view — always run this first |
| One-off, interactive partitioning on a small/legacy MBR disk | **`fdisk`** | Simplest menu workflow, safe (nothing committed until `w`) |
| Scripted/automated provisioning, GPT disks, disks >2TiB | **`parted -s`** | Only one of the three with a real non-interactive scripting mode |

**Bottom line: `lsblk` to look, `fdisk` for quick interactive MBR/simple work, `parted --script` for anything GPT, large, or automated.**

## Hands-On Examples

**1. Inspect attached block devices**
```bash
$ lsblk
NAME        MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
sda           8:0    0    50G  0 disk
├─sda1        8:1    0     1G  0 part /boot
└─sda2        8:2    0    49G  0 part /
nvme0n1     259:0    0   500G  0 disk
└─nvme0n1p1 259:1    0   500G  0 part /data
```

**2. Show filesystem type and UUID per device**
```bash
$ lsblk -f
NAME        FSTYPE FSVER LABEL UUID                                 MOUNTPOINT
sda
├─sda1      ext4   1.0         3a1f9e2c-...-8b21          /boot
└─sda2      xfs                a9c4e881-...-11d3          /
nvme0n1
└─nvme0n1p1 ext4   1.0         c7e0a2f4-...-99a1          /data
```

**3. List partition table details with `fdisk`**
```bash
$ sudo fdisk -l /dev/sdb
Disk /dev/sdb: 100 GiB, 107374182400 bytes, 209715200 sectors
Disklabel type: gpt
Disk identifier: 4F2A9E3C-...

Device     Start       End   Sectors  Size Type
```
Disk is blank — no partitions yet.

**4. Create a new GPT partition interactively with `fdisk`**
```bash
$ sudo fdisk /dev/sdb

Welcome to fdisk (util-linux 2.38.1).

Command (m for help): g
Created a new GPT disklabel (GUID: 4F2A9E3C-...).

Command (m for help): n
Partition number (1-128, default 1): 1
First sector: [Enter for default]
Last sector: +50G

Created a new partition 1 of type 'Linux filesystem' and of size 50 GiB.

Command (m for help): w
The partition table has been altered.
Calling ioctl() to re-read partition table.
Syncing disks.
```

**5. Same task, non-interactively with `parted` (scriptable/automation-friendly)**
```bash
$ sudo parted -s /dev/sdc mklabel gpt
$ sudo parted -s /dev/sdc mkpart primary ext4 0% 100%
$ sudo parted -s /dev/sdc print
Model: VMware Virtual disk (scsi)
Disk /dev/sdc: 107GB
Sector size (logical/physical): 512B/512B
Partition Table: gpt

Number  Start   End    Size   File system  Name     Flags
 1      1049kB  107GB  107GB               primary
```

**6. Make the kernel see a newly created/changed partition table without rebooting**
```bash
$ sudo partprobe /dev/sdc
$ lsblk /dev/sdc
NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
sdc      8:32   0  100G  0 disk
└─sdc1   8:33   0  100G  0 part
```

**7. Production scenario: a new 3TB cloud volume is attached — MBR would silently cap it**
```bash
$ lsblk
nvme1n1     259:2    0     3T  0 disk
$ sudo fdisk -l /dev/nvme1n1 | grep "Disklabel type"
Disklabel type: dos                 # MBR — WRONG for a 3TB disk, max addressable ~2TiB

$ sudo parted -s /dev/nvme1n1 mklabel gpt
$ sudo parted -s /dev/nvme1n1 mkpart primary xfs 0% 100%
$ sudo parted /dev/nvme1n1 print
Disk /dev/nvme1n1: 3299GB
Partition Table: gpt
Number  Start   End     Size    File system  Name     Flags
 1      1049kB  3299GB  3299GB               primary
```
GPT was required here — an MBR table on this disk would have silently truncated usable space to ~2TiB.

## Practice Questions

1. A colleague runs `fdisk -l` on a 4TB disk and only ~2TiB shows up as usable in the partition table. What's the root cause and how do you fix it?
2. What's the practical difference between `fdisk` and `parted` when you need to provision 50 identical disks via an Ansible playbook?
3. You just created a partition with `parted`, but `lsblk` on a different terminal session still doesn't show it. What command fixes this without a reboot?
4. Walk through the exact `fdisk` interactive sequence to create a new GPT primary partition using the whole disk.
5. What does `lsblk -f` show that plain `lsblk` doesn't, and when would you need that extra information?
6. Why doesn't `parted mkpart` alone make a partition usable for storing files — what step(s) are still missing?
7. What's the maximum number of primary partitions on an MBR disk, and how did the "extended partition" concept work around that historically?
8. A script needs to partition a disk with zero user interaction as part of a cloud-init boot process. Which tool do you reach for and why?
9. How would you find the UUID of `/dev/sdb1` to use in `/etc/fstab`, using two different commands?

## Real Interview Questions (Company-Attributed)

- "Explain the use of `lsblk` and `blkid`." — asked at *Sigmoid* (part of a rapid-fire "explain these Linux commands" interview round)

## Interview Key Points

- **MBR caps at ~2TiB and 4 primary partitions; GPT removes both limits** — this is the single fact interviewers most often probe with a "why did partitioning fail on this large disk" scenario.
- `lsblk` is read-only/inspection only — never confuse it with a tool that can modify partition tables.
- `fdisk` writes nothing to disk until you type `w` (commit) — a genuinely safe tool to explore in; `q` aborts with zero changes.
- `parted --script` (`-s`) is the automation-friendly path — know this cold, since "how would you script this" is a common senior-level follow-up.
- Creating a partition is **not** the same as creating a filesystem — `fdisk`/`parted` only write the partition table; `mkfs.*` is a separate required step (covered in the next topic).
- After partitioning a live disk without rebooting, the kernel may not see the change — `partprobe` or `partx -a` forces a re-read; forgetting this is a common "why isn't my new partition showing up" gotcha.
- `blkid` and `lsblk -f` both surface UUID/LABEL/fstype — know at least one cold, since fstab entries should reference UUIDs, not raw device names (device names can shift on reboot).
