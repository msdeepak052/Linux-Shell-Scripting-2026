# LVM: Physical Volumes, Volume Groups, Logical Volumes

LVM adds a flexible abstraction layer between raw disks and filesystems, letting you resize, extend across disks, and snapshot volumes without unmounting anything.

## Explanation

**The three layers**:
- **Physical Volume (PV)** — a raw disk or partition initialized for LVM use (`pvcreate`). Carries an LVM header/metadata area.
- **Volume Group (VG)** — a pool made of one or more PVs (`vgcreate`). Storage is pooled and allocated in fixed-size chunks called **Physical Extents (PEs)**, default 4MiB.
- **Logical Volume (LV)** — a virtual block device carved out of a VG (`lvcreate`), addressed via `/dev/<vg_name>/<lv_name>` or `/dev/mapper/<vg_name>-<lv_name>`. Filesystems are created and mounted on top of LVs, never directly on VGs.

**Why LVM matters in production**: you can add a PV to a VG and extend an LV+filesystem **online**, with zero downtime, when a mount point runs low on space — no repartitioning, no outage window. You can also take **snapshots** (COW-based) for consistent backups of a live volume, and use **`pvmove`** to migrate data off a failing disk while the VG stays online.

**Key commands**:
```
pvcreate /dev/sdb1              # initialize a partition/disk as a PV
pvdisplay / pvs                 # show PVs
vgcreate vg_data /dev/sdb1      # create VG from PV(s)
vgextend vg_data /dev/sdc1      # add another PV to an existing VG
vgdisplay / vgs                 # show VGs
lvcreate -n lv_app -L 20G vg_data     # create a 20G LV
lvcreate -n lv_app -l 100%FREE vg_data # use all remaining free extents
lvextend -L +10G /dev/vg_data/lv_app  # grow LV by 10G
lvextend -r -L +10G /dev/vg_data/lv_app  # grow LV AND resize filesystem in one step
lvreduce -L -5G ...              # shrink (DANGEROUS — resize filesystem FIRST, only for ext4, not xfs)
lvdisplay / lvs                  # show LVs
```

**Resizing filesystems after `lvextend`**:
- ext4: `resize2fs /dev/vg_data/lv_app` (works online, while mounted, growing only)
- xfs: `xfs_growfs /mount/point` (mount point, not device; XFS can ONLY grow, never shrink — no `xfs_shrink` exists)

**Gotchas**:
- `lvextend` growing the LV does NOT automatically grow the filesystem — you must run `resize2fs`/`xfs_growfs` afterward, unless you pass `-r`/`--resizefs` to `lvextend` which does both atomically.
- **Shrinking is filesystem-order-sensitive and risky**: for ext4 you must `umount` → `e2fsck -f` → `resize2fs` (shrink) → THEN `lvreduce`. Doing it in the wrong order destroys data.
- **XFS cannot shrink, period** — not the LV, not the filesystem. If you undersized an XFS LV, the only fix is backup/recreate/restore, or add more space.
- Deleting a PV/VG/LV is irreversible without backups — always confirm with `lvs`/`vgs`/`pvs` before destructive operations.
- `vgs`/`lvs`/`pvs` are the modern, scriptable, terse report commands; `vgdisplay`/`lvdisplay`/`pvdisplay` are the older, more verbose ones. Know both.
- LVM metadata backups live in `/etc/lvm/backup/` and `/etc/lvm/archive/` — useful for `vgcfgrestore` disaster recovery.

## Hands-On Examples

**1. Building the stack from scratch**
```bash
$ pvcreate /dev/sdb1 /dev/sdc1
  Physical volume "/dev/sdb1" successfully created.
  Physical volume "/dev/sdc1" successfully created.

$ vgcreate vg_data /dev/sdb1 /dev/sdc1
  Volume group "vg_data" successfully created

$ lvcreate -n lv_app -L 50G vg_data
  Logical volume "lv_app" created.

$ mkfs.ext4 /dev/vg_data/lv_app
$ mount /dev/vg_data/lv_app /app
```

**2. Checking capacity across all three layers**
```bash
$ pvs
  PV         VG      Fmt  Attr PSize    PFree
  /dev/sdb1  vg_data lvm2 a--   <100.00g   50.00g
  /dev/sdc1  vg_data lvm2 a--   <100.00g  100.00g

$ vgs
  VG      #PV #LV #SN Attr   VSize   VFree
  vg_data   2   1   0 wz--n- 199.99g 150.00g

$ lvs
  LV     VG      Attr       LSize  Pool Origin Data%
  lv_app vg_data -wi-ao---- 50.00g
```

**3. Production scenario: /app is almost full, extend it live (no downtime)**
```bash
$ df -h /app
Filesystem                 Size  Used Avail Use% Mounted on
/dev/mapper/vg_data-lv_app  50G   47G  1.1G  98% /app

$ vgs
  VG      #PV #LV #SN Attr   VSize   VFree
  vg_data   2   1   0 wz--n- 199.99g 150.00g   # plenty of free extents in the VG

$ lvextend -r -L +30G /dev/vg_data/lv_app
  Size of logical volume vg_data/lv_app changed from 50.00 GiB to 80.00 GiB.
  Logical volume vg_data/lv_app successfully resized.
resize2fs 1.46.5 (30-Dec-2021)
Filesystem at /dev/mapper/vg_data-lv_app is mounted on /app; on-line resizing required
The filesystem on /dev/mapper/vg_data-lv_app is now 20971520 (4k) blocks long.

$ df -h /app
Filesystem                 Size  Used Avail Use% Mounted on
/dev/mapper/vg_data-lv_app  79G   47G   29G  63% /app
```

**4. Adding a new disk to an existing VG that's running out of room**
```bash
$ vgs
  VG      #PV #LV #SN Attr   VSize   VFree
  vg_data   2   1   0 wz--n- 199.99g    2.00g   # nearly exhausted

$ pvcreate /dev/sdd1
  Physical volume "/dev/sdd1" successfully created.

$ vgextend vg_data /dev/sdd1
  Volume group "vg_data" successfully extended

$ vgs
  VG      #PV #LV #SN Attr   VSize   VFree
  vg_data   3   1   0 wz--n- 299.99g  102.00g
```

**5. Using all remaining free space for a new LV, XFS growfs**
```bash
$ lvcreate -n lv_logs -l 100%FREE vg_data
  Logical volume "lv_logs" created.

$ mkfs.xfs /dev/vg_data/lv_logs
$ mount /dev/vg_data/lv_logs /var/log/app

# later, after lvextend to grow the LV further
$ lvextend -L +20G /dev/vg_data/lv_logs
$ xfs_growfs /var/log/app        # note: mount POINT, not device, for xfs_growfs
meta-data=/dev/mapper/vg_data-lv_logs isize=512    agcount=4, agsize=6553600 blks
data blocks changed from 26214400 to 31457280
```

**6. Shrinking an ext4 LV safely (offline, correct order)**
```bash
$ umount /app
$ e2fsck -f /dev/vg_data/lv_app
$ resize2fs /dev/vg_data/lv_app 40G
resize2fs 1.46.5: The filesystem on /dev/vg_data/lv_app is now 10485760 (4k) blocks long.

$ lvreduce -L 40G /dev/vg_data/lv_app
  WARNING: Reducing active logical volume to 40.00 GiB.
  THIS MAY DESTROY YOUR DATA (filesystem data not resized first)!
Do you really want to reduce lv_app? [y/n]: y
  Size of logical volume vg_data/lv_app changed from 80.00 GiB to 40.00 GiB.

$ mount /dev/vg_data/lv_app /app
```

**7. LVM snapshot for a consistent backup of a live volume**
```bash
$ lvcreate -s -n lv_app_snap -L 5G /dev/vg_data/lv_app
  Logical volume "lv_app_snap" created.

$ mount -o ro /dev/vg_data/lv_app_snap /mnt/snap
$ tar -czf /backups/app_$(date +%F).tar.gz -C /mnt/snap .
$ umount /mnt/snap
$ lvremove -f /dev/vg_data/lv_app_snap
  Logical volume "vg_data/lv_app_snap" successfully removed.
```

**8. Investigating why `lvcreate` fails — insufficient free extents**
```bash
$ lvcreate -n lv_new -L 200G vg_data
  Volume group "vg_data" has insufficient free space (25599 extents): 51200 required.

$ vgs -o vg_name,vg_free vg_data
  VG      VFree
  vg_data  99.99g
# only ~100G free, requested 200G — need vgextend with another PV first
```

## Practice Questions

1. Walk through the full stack: what's the difference between a PV, a VG, and an LV, and why can't you `mkfs` directly on a VG?
2. `/data` is at 95% and you need to add 20G. Walk through the exact commands from checking VG free space to the filesystem showing the new size, live, with no unmount.
3. You ran `lvextend -L +20G /dev/vg_data/lv_app` but `df -h` still shows the old size. What step did you miss, and what single flag to `lvextend` would have avoided this?
4. Why can XFS filesystems never be shrunk, and what's your only recourse if an XFS-backed LV was undersized?
5. Describe the correct, safe order of operations to shrink an ext4 LV from 80G to 40G. What happens if you run `lvreduce` before `resize2fs`?
6. A VG has two PVs and is almost full. What command adds a third disk to the pool, and what do you check beforehand to confirm the new PV registered?
7. What is an LVM snapshot, how does copy-on-write make it space-efficient, and why would you use one before a backup instead of just backing up the live mounted filesystem directly?
8. `pvs`/`vgs`/`lvs` vs `pvdisplay`/`vgdisplay`/`lvdisplay` — what's the practical difference, and which would you reach for in a script versus interactively?
9. `lvcreate -n lv_new -L 200G vg_data` fails with "insufficient free space." What are the two possible fixes, and which commands would you run for each?
10. Where does LVM store its metadata backups, and what command would you use to restore a VG's configuration from one, e.g., after accidentally deleting an LV?

## Real Interview Questions (Company-Attributed)

- "Add 50GB to `/opt` using LVM without any downtime — what are the steps?" — asked at *an unnamed company (via community-sourced interview notes)*

## Interview Key Points

- Know the hierarchy cold: PV → VG → LV, and that filesystems sit only on LVs, never directly on VGs or raw disks (though they technically can on a PV, that defeats the purpose).
- **Live/online resize is the headline feature** — extending an LV and growing ext4/XFS on top requires zero downtime; this is the #1 reason production shops use LVM over raw partitions.
- `lvextend` does NOT resize the filesystem automatically — always mention `-r`/`--resizefs`, or the manual `resize2fs`/`xfs_growfs` follow-up; forgetting this is the most common "gotcha" interview trap.
- **XFS can only grow, never shrink** — a very frequently tested fact. ext4 can do both but shrinking requires unmount + `e2fsck -f` + `resize2fs` BEFORE `lvreduce`.
- Snapshots are copy-on-write and space-efficient but not infinite — if a snapshot's allocated space fills up (heavy writes to the origin), the snapshot becomes invalid/unusable.
- `vgextend` + `pvcreate` is how you grow storage capacity across multiple physical disks without touching existing mount points or filesystems.
- LVM metadata lives in `/etc/lvm/backup/` (current) and `/etc/lvm/archive/` (historical) — `vgcfgrestore` is the disaster-recovery command to know.
- Be able to explain "why LVM over plain partitions" in one sentence: flexibility to resize, span multiple disks, and snapshot — at the cost of a small extra abstraction/complexity layer.
