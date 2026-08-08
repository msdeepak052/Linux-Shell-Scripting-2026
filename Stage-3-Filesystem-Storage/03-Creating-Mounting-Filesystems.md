# Creating & Mounting Filesystems: `mkfs`, `mount`, `umount`, `/etc/fstab`

Turning a raw partition into something you can actually store files on, and making that survive a reboot — one of the most common day-1 platform-engineering tasks.

## Explanation

### The pipeline: partition → filesystem → mountpoint → fstab
1. **`mkfs.<type>`** writes an actual filesystem structure (superblock, inode tables, journal, etc.) onto a partition or raw block device — `mkfs.ext4 /dev/sdb1`, `mkfs.xfs /dev/sdb1`. Without this step the partition is just empty space; nothing can be stored on it.
2. **`mount`** attaches that filesystem's root directory to an existing empty directory (the **mountpoint**) in your existing directory tree, making its contents accessible at that path. `mount /dev/sdb1 /data` — from that point, anything under `/data` reads/writes to `/dev/sdb1`.
3. **`/etc/fstab`** is what makes a mount **persistent across reboots** — without an fstab entry (or a systemd `.mount` unit), a manual `mount` disappears the moment the system reboots.

### `/etc/fstab` field-by-field
```
UUID=c7e0a2f4-...   /data   ext4   defaults,nofail   0   2
```
| Field | Meaning |
|---|---|
| 1 | Device — **prefer `UUID=` or `LABEL=`**, not `/dev/sdb1` (device names can shift between boots, especially with multiple disks attached — a UUID is stable and tied to the actual filesystem) |
| 2 | Mountpoint |
| 3 | Filesystem type (`ext4`, `xfs`, `swap`, etc.) |
| 4 | Mount options, comma-separated (`defaults`, `noatime`, `ro`, `nofail`) |
| 5 | `dump` utility flag (0 = don't back up; almost always 0 today) |
| 6 | `fsck` pass order at boot (0 = never check, 1 = root filesystem, 2 = checked after root) |

`nofail` deserves special mention: without it, if that device is **missing at boot** (unplugged disk, detached cloud volume), the boot can hang or drop to an emergency shell waiting for it. `nofail` tells systemd to continue booting even if the mount fails — important for any non-root data volume.

### `umount` and "device is busy"
`umount /data` fails with `target is busy` if any process has an open file handle or working directory inside that mount. Diagnose with `lsof +D /data` or `fuser -vm /data` to see exactly what's holding it open, then either stop that process or, as a last resort, `umount -l /data` (**lazy unmount** — detaches immediately from the namespace but the actual unmount completes only once nothing references it anymore; use with caution, it can mask a problem rather than fix it).

## Hands-On Examples

**1. Full pipeline on a brand-new disk**
```bash
$ lsblk /dev/sdb
sdb    8:16   0   50G  0 disk

$ sudo mkfs.ext4 /dev/sdb
mke2fs 1.46.5 (30-Dec-2021)
Creating filesystem with 13107200 4k blocks and 3276800 inodes
Writing superblocks and filesystem accounting information: done

$ sudo mkdir -p /data
$ sudo mount /dev/sdb /data
$ df -h /data
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdb         49G   24K   47G   1% /data
```

**2. Find the UUID and add a persistent fstab entry**
```bash
$ sudo blkid /dev/sdb
/dev/sdb: UUID="c7e0a2f4-88b1-4e91-9a3d-1f2e8b0c9a11" BLOCK_SIZE="4096" TYPE="ext4"

$ echo 'UUID=c7e0a2f4-88b1-4e91-9a3d-1f2e8b0c9a11  /data  ext4  defaults,nofail  0  2' | sudo tee -a /etc/fstab
```

**3. Test the fstab entry WITHOUT rebooting (critical habit)**
```bash
$ sudo umount /data
$ sudo mount -a
$ df -h /data
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdb         49G   24K   47G   1% /data
```
`mount -a` mounts everything listed in `/etc/fstab` that isn't already mounted — this is exactly what happens at boot, so running it manually is the standard way to catch a typo *before* it causes a boot failure.

**4. Diagnose and resolve "device is busy" on unmount**
```bash
$ sudo umount /data
umount: /data: target is busy.

$ sudo fuser -vm /data
                     USER        PID ACCESS COMMAND
/data:               appuser    4821 ..c.   tail
                     appuser    4822 f...   java

$ sudo kill 4821
$ sudo systemctl stop myapp.service   # cleanly stop the process holding 4822
$ sudo umount /data
```

**5. Mount options in action — read-only and remounting**
```bash
$ sudo mount -o ro /dev/sdc1 /mnt/archive
$ touch /mnt/archive/test
touch: cannot touch '/mnt/archive/test': Read-only file system

$ sudo mount -o remount,rw /mnt/archive     # remount without unmounting
```

**6. Bind mount — same content, two paths (common in containers/chroots)**
```bash
$ sudo mount --bind /var/lib/docker /mnt/docker-data
$ df -h /mnt/docker-data
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p1  100G   40G   55G  43% /mnt/docker-data
```

**7. Production scenario: cloud volume missing at boot without `nofail`**
```bash
# /etc/fstab WITHOUT nofail:
# UUID=xxxx  /data  ext4  defaults  0  2
# -> EBS volume detached before reboot -> system hangs at boot in emergency mode
#    waiting for /data to appear, requiring console access to fix.

# Corrected entry:
UUID=c7e0a2f4-...  /data  ext4  defaults,nofail  0  2
```
This is a real production incident pattern: always use `nofail` (and often `noauto` if the mount is genuinely optional) on any non-root filesystem so a missing/slow-to-attach disk never blocks the whole boot.

## Practice Questions

1. You create a filesystem with `mkfs.ext4` and try `mount /dev/sdb1 /data` immediately — it works, but after a reboot `/data` is empty again. What step did you skip?
2. Why should `/etc/fstab` reference a device by `UUID=` rather than `/dev/sdb1`? Give a concrete scenario where the device-name approach breaks.
3. What does the `nofail` mount option do, and what production incident does omitting it risk?
4. `umount /mnt/data` returns "target is busy." Walk through exactly how you'd find and resolve the cause.
5. What's the difference between `umount` and `umount -l`, and why is `-l` considered a last resort rather than a routine fix?
6. How do you safely test a new `/etc/fstab` entry for correctness without rebooting the server?
7. Explain what a bind mount (`mount --bind`) does differently from a normal filesystem mount.
8. What do the 5th and 6th fields in an `/etc/fstab` line control, and what values would you set for a secondary data disk versus the root filesystem?
9. A junior engineer edits `/etc/fstab` by hand, makes a typo, and reboots the server — it drops to an emergency shell. How would you have prevented this, and how do you recover from it?

## Real Interview Questions (Company-Attributed)

- "In Linux, how do you attach and detach a filesystem?" — asked at *an unnamed company (via community-sourced interview notes)*
- "What's the difference between a mount and a directory in Linux?" — asked at *Netcracker, Amazon*
- "How do you find the mount point space usage on a Linux system?" — asked at *TCS*
- "What is the Linux command used for mounting a filesystem?" — asked at *Accion Labs*
- "Explain the use of `mkfs`." — asked at *Sigmoid* (part of a rapid-fire "explain these Linux commands" interview round)

## Interview Key Points

- **`mkfs` creates the filesystem, `mount` attaches it, `/etc/fstab` makes that persist** — three distinct steps; interviewers often check whether you conflate any two of them.
- Always use `UUID=` (or `LABEL=`) in fstab, never a raw device path — device enumeration order isn't guaranteed stable across reboots, especially with multiple disks or after hardware changes.
- `nofail` is a genuine production-safety habit for non-root volumes — omitting it can turn a detached/slow cloud disk into a full boot hang.
- `mount -a` after editing fstab is the standard "verify before you reboot" move — cheap, catches typos immediately instead of at the worst possible time.
- "Device busy" on unmount means an open file handle or working directory inside the mount — `lsof`/`fuser` finds the culprit; `umount -l` (lazy) is a workaround, not a real fix, and can hide the underlying issue.
- Know the difference between a plain mount (attaches a filesystem) and a bind mount (`--bind`, re-exposes an existing directory tree at another path, same underlying filesystem) — a favorite "what does this do differently" question.
- Remounting with new options (`mount -o remount,ro`) avoids a full unmount/mount cycle — useful for changing options on a busy filesystem you can't unmount.
