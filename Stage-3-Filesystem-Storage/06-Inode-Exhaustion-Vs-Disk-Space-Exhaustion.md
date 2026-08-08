# Inode Exhaustion vs Disk-Space Exhaustion

"Disk full" has two completely different root causes — running out of storage bytes, or running out of inodes (the fixed-count metadata structures filesystems allocate at creation time) — and they need different diagnosis and different fixes.

## Explanation

**What an inode is**: every file, directory, symlink, and special file on a Unix filesystem needs one inode — a metadata structure storing permissions, owner, timestamps, size, and pointers to data blocks (NOT the filename itself; that lives in the directory entry). Ext-family filesystems (ext2/3/4) allocate a **fixed number of inodes at `mkfs` time**, sized proportionally to the filesystem size using a "bytes-per-inode" ratio. Once that count is exhausted, **you cannot create a single new file or directory, even if there are terabytes of free space**, because there's no inode structure left to describe it.

**The classic scenario ("disk full but `df` shows space")**: `df -h` reports plenty of free bytes, but `touch newfile` / application writes fail with `ENOSPC: No space left on device`. This happens when a filesystem holds **millions of tiny files** (session cache files, mail spool files, tiny log fragments, npm `node_modules` trees, etc.) — you exhaust the inode table long before you exhaust the block/byte space. `df -i` (not `df -h`) is the diagnostic command that reveals this.

**Why it happens in practice**:
- Applications that create huge numbers of small files: mail servers (Maildir format = 1 file per email), session stores, build caches, `node_modules`, PHP session files in `/tmp`, log rotation gone wrong (millions of `.gz` fragments), core dumps.
- Default inode ratios assume "average" file sizes; workloads with abnormally many tiny files break that assumption.
- **XFS is more resistant** — it allocates inodes dynamically (not fixed at creation), so classic inode exhaustion mostly affects ext2/3/4 (and even XFS has a practical/configurable ceiling via `maxpct`, though it's rarely hit).

**Finding directories with millions of small files**:
```
df -i                                    # confirm: IUse% near 100% = inode exhaustion
find /path -xdev -printf '.' | wc -c     # count files fast (no newline overhead)
find /path -xdev -type f | wc -l         # count regular files under a path
du --inodes -h --max-depth=1 /path       # (util-linux/coreutils newer versions) inode count per subdir
for d in /var/*; do echo "$d: $(find "$d" -xdev | wc -l)"; done   # per-directory inode census
```

**Fixing it**:
- Short-term: delete/archive the excess tiny files (mail spool cleanup, cache purge, stale session files).
- Root cause fix: re-`mkfs` with a smaller `bytes-per-inode` ratio (`mkfs.ext4 -i 4096 ...` for more inodes) sized for the actual workload, or migrate that mount to XFS.
- Check inode ratio at creation time: `mkfs.ext4 -i 16384` (default varies by distro, roughly 1 inode per 16KB) — for a workload with tons of tiny files, use `-i 4096` or smaller to get more inodes for the same disk size (trades some space for more inode capacity).
- You **cannot** change the total inode count of an existing ext4 filesystem without reformatting (`tune2fs` cannot add inodes after creation) — this must be planned ahead, or fixed by migrating data to a freshly formatted filesystem/LV.

## Hands-On Examples

**1. The classic symptom — write fails, `df -h` looks fine**
```bash
$ touch /var/spool/mail/newfile
touch: cannot touch '/var/spool/mail/newfile': No space left on device

$ df -h /var
Filesystem                  Size  Used Avail Use% Mounted on
/dev/mapper/vg_data-lv_var   20G  8.1G   12G  41% /var    # plenty of space!
```

**2. The real diagnostic — check inodes, not blocks**
```bash
$ df -i /var
Filesystem                   Inodes  IUsed   IFree IUse% Mounted on
/dev/mapper/vg_data-lv_var  1310720 1310716       4  100% /var    # inode table exhausted
```

**3. Finding which subdirectory is hoarding inodes**
```bash
$ for d in /var/*/; do printf "%-30s %s\n" "$d" "$(find "$d" -xdev 2>/dev/null | wc -l)"; done | sort -k2 -rn
/var/spool/                    1204331
/var/log/                       89210
/var/lib/                       12455
/var/cache/                      3890
```

**4. Drilling into the offender**
```bash
$ find /var/spool -xdev -maxdepth 2 -type d | while read -r d; do
    echo "$(find "$d" -maxdepth 1 -xdev | wc -l) $d"
  done | sort -rn | head -5
1204102 /var/spool/mail/appuser
    150 /var/spool/cron
     45 /var/spool/postfix
```

**5. Confirming and cleaning up (mail spool with a runaway Maildir)**
```bash
$ find /var/spool/mail/appuser -type f | wc -l
1204102

$ find /var/spool/mail/appuser -type f -mtime +90 -delete
$ df -i /var
Filesystem                   Inodes  IUsed   IFree IUse% Mounted on
/dev/mapper/vg_data-lv_var  1310720  312890  997830   24%  /var    # inodes freed
```

**6. Preventing recurrence — reformat with a higher inode budget**
```bash
$ umount /var
$ mkfs.ext4 -i 4096 /dev/vg_data/lv_var       # 1 inode per 4KB instead of default ~16KB = 4x more inodes
mke2fs 1.46.5
Creating filesystem with 5242880 4k blocks and 5242880 inodes
$ mount /dev/vg_data/lv_var /var
$ df -i /var
Filesystem                   Inodes  IUsed  IFree IUse% Mounted on
/dev/mapper/vg_data-lv_var  5242880  312890 4929990    6%  /var
```

**7. Same investigation but for actual space exhaustion (the "normal" case, for contrast)**
```bash
$ df -h /app
Filesystem                Size  Used Avail Use% Mounted on
/dev/mapper/vg_data-lv_app  80G   80G     0 100% /app

$ df -i /app
Filesystem                  Inodes  IUsed   IFree IUse% Mounted on
/dev/mapper/vg_data-lv_app 5242880  45210 5197670    1%  /app   # inodes totally fine — this IS real space exhaustion
$ du -h --max-depth=1 /app | sort -rh | head -3
78G     /app/data
1.2G    /app/logs
```

**8. XFS example — inode allocation is dynamic, exhaustion is rare but not impossible**
```bash
$ df -i /xfsdata
Filesystem      Inodes   IUsed   IFree IUse% Mounted on
/dev/sdd1     839452032  839451000    1032  100%   /xfsdata
# XFS allocates inodes on demand up to a % of space (imaxpct, default 25% on small fs, 5-25% on large)
# still possible to exhaust with truly enormous small-file counts, but far rarer than ext4
$ xfs_info /xfsdata | grep imaxpct
data     =                       imaxpct=25
```

## Practice Questions

1. What exactly is an inode, and why is filename NOT part of it? Where does the filename actually live?
2. A team reports "disk full" errors from their app, but `df -h` shows 40% used. What's your first diagnostic command, and what would confirm inode exhaustion?
3. Why does ext4 have a fixed inode count decided at `mkfs` time, while XFS mostly avoids this class of problem?
4. Give three real-world workload patterns that commonly cause inode exhaustion.
5. `df -i` shows `IUse% 100%` on `/var`. Write a command sequence to find which top-level subdirectory of `/var` is consuming the most inodes.
6. Can you increase the inode count of an already-formatted, in-use ext4 filesystem without data loss, using `tune2fs` or similar, while it stays mounted? What's the actual fix?
7. You need to reformat a filesystem to support far more small files than the default `mkfs.ext4` inode ratio allows. What flag controls this, and what's the tradeoff of setting it very low (e.g., `-i 1024`)?
8. Explain, step by step, how you'd distinguish "real disk space exhaustion" from "inode exhaustion" given only shell access and no monitoring dashboard.
9. A Maildir-based mail spool has 1.2 million tiny files and is the root cause of inode exhaustion on `/var`. Besides deleting old mail, what longer-term architectural fix would you propose?
10. What does XFS's `imaxpct` setting control, and how would you check it and confirm XFS is (or isn't) close to its own inode ceiling?

## Real Interview Questions (Company-Attributed)

- "The filesystem shows 50% usage but you can't write to it, and `df -i` shows it's full — what's going on?" — asked at *an unnamed company (via community-sourced interview notes)*

## Interview Key Points

- **This is one of the most commonly asked "gotcha" scenarios in senior Linux interviews**: "df shows free space but I can't create files — why?" The answer is always inode exhaustion — say it immediately, then show `df -i`.
- Core fact to state cold: **ext2/3/4 fix the total inode count at `mkfs` time**; it cannot be changed later without reformatting. XFS allocates inodes dynamically, so it's far more resistant (though not immune, governed by `imaxpct`).
- **`df -i` is the diagnostic**, not `df -h` — know to reach for it the instant "no space left on device" appears alongside apparently-free disk space.
- Root causes to name from memory: Maildir-style mail spools, session/cache directories, `node_modules`-style dependency trees, runaway log rotation producing millions of fragments.
- Fixing it live means **deleting/archiving files**, not resizing anything — there is no live "add more inodes" operation for ext4; the only permanent fix is reformatting with a lower `bytes-per-inode` ratio (`-i` flag to `mkfs.ext4`) or moving the workload to XFS.
- Know the terminology: "bytes-per-inode ratio" (mkfs `-i` flag) controls how many inodes get created relative to filesystem size — smaller ratio = more inodes = better for many-small-files workloads, at a small fixed metadata overhead cost.
- Be ready to write the `find | wc -l` / per-directory inode census one-liners live — this is a common practical/whiteboard exercise, not just a definitional question.
