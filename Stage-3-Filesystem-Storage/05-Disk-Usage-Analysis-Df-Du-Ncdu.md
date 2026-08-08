# Disk Usage Analysis: `df`, `du`, `ncdu`

Diagnosing "disk full" incidents fast depends on knowing which tool answers which question — `df` for filesystem-level space, `du` for directory/file-level breakdown, `ncdu` for interactively hunting down the culprit.

## Explanation

**`df` (disk free)** — reports space at the **filesystem/mount point** level, reading kernel-cached superblock stats. Fast (doesn't walk the tree).
```
df -h              # human-readable sizes (G/M/K)
df -h /var         # just the filesystem containing /var
df -i              # inode usage instead of block usage
df -T              # show filesystem type column
df -x tmpfs         # exclude a filesystem type from output
```

**`du` (disk usage)** — walks a directory tree and sums actual file sizes (or block allocation). Can be slow on huge trees since it's a real traversal.
```
du -sh /var/log          # summary (-s), human-readable, for one path
du -sh /var/log/*        # per-subdirectory sizes, one level
du -h --max-depth=1 /var | sort -rh   # sorted, top offenders at depth 1
du -x -sh /                # stay on one filesystem (-x), don't cross into other mounts (e.g. NFS, /proc)
du -a                       # include files, not just directories, in output
du --apparent-size          # logical file size vs actual disk blocks used (differs with sparse files, compression)
```

**`ncdu`** (NCurses Disk Usage) — interactive TUI wrapper around `du`-style scanning; lets you navigate into directories, sort by size, and delete files right from the UI. The go-to tool for actually finding what's eating disk space fast, versus manually running `du` repeatedly.
```
ncdu /                 # scan and browse interactively
ncdu -x /               # stay on one filesystem, don't cross mounts
ncdu -o scan.ncdu /     # export scan to a file for later/offline viewing
ncdu -f scan.ncdu       # load a previously exported scan
```

**Key gotchas / interview traps**:
- `df` and `du` can **disagree** — most commonly, a large file is deleted but still held open by a running process. `df` shows the space as used (the kernel hasn't freed the inode/blocks because a file descriptor is still open); `du` (which walks the current directory tree) doesn't see the deleted file at all and reports less used space. Fix: find and restart/reload the process holding the deleted file (`lsof +L1` or `lsof | grep deleted`).
- `du` reports **apparent allocation on disk** (in blocks) by default, which can be *larger* than file size for small files (block rounding) or *smaller* for sparse files (unless `--apparent-size` is used).
- `df` percentages can hit 100% "used" even with `df` reporting free bytes remaining, because ext-family filesystems reserve ~5% of space for root (`tune2fs -l` shows "Reserved block count") — normal users see less available than the raw math suggests.
- `du` without `-x` will recurse into other mounted filesystems (bind mounts, NFS shares) under the path, giving misleading/slow results — always use `-x` when checking usage on the root filesystem.
- `df -i` (inodes) is a completely separate exhaustion mode from block/space exhaustion — see file 06 for the deep dive.

## Hands-On Examples

**1. Quick filesystem-level overview**
```bash
$ df -h
Filesystem                 Size  Used Avail Use% Mounted on
/dev/mapper/vg_root-lv_root  20G   18G  1.1G  95% /
/dev/mapper/vg_data-lv_app   80G   74G  6.0G  93% /app
tmpfs                        3.9G     0  3.9G   0% /dev/shm
/dev/sda1                    1G  180M  844M  18% /boot
```

**2. Filter noise, show filesystem type**
```bash
$ df -hT -x tmpfs -x devtmpfs
Filesystem                   Type  Size  Used Avail Use% Mounted on
/dev/mapper/vg_root-lv_root  xfs    20G   18G  1.1G  95% /
/dev/mapper/vg_data-lv_app   xfs    80G   74G  6.0G  93% /app
/dev/sda1                    ext4    1G  180M  844M  18% /boot
```

**3. Finding the biggest directories under `/var`**
```bash
$ du -h --max-depth=1 /var 2>/dev/null | sort -rh
12G     /var
9.8G    /var/log
1.4G    /var/lib
600M    /var/cache
120M    /var/spool
```

**4. Drilling further into the offender**
```bash
$ du -h --max-depth=1 /var/log 2>/dev/null | sort -rh
9.8G    /var/log
7.2G    /var/log/app
1.9G    /var/log/audit
400M    /var/log/journal
$ ls -lhS /var/log/app | head -5
-rw-r--r-- 1 appuser appuser 6.8G Aug  8 14:02 app-debug.log
-rw-r--r-- 1 appuser appuser 220M Aug  7 23:59 app-debug.log.1
```

**5. The classic `df` vs `du` mismatch — deleted-but-open file**
```bash
$ df -h /app
Filesystem                Size  Used Avail Use% Mounted on
/dev/mapper/vg_data-lv_app  80G   74G  6.0G  93% /app

$ du -sh /app
40G     /app                     # 34G unaccounted for!

$ lsof +L1 | grep app             # find open files with link count 0 (deleted but held open)
java      4821 appuser   15w   REG   253,1  34000000000    0  1234567 /app/logs/heap.log (deleted)

$ kill -HUP 4821                  # or restart the service properly to release the fd
# after service reload/restart:
$ df -h /app
Filesystem                Size  Used Avail Use% Mounted on
/dev/mapper/vg_data-lv_app  80G   40G  40G  50% /app
```

**6. Interactive investigation with `ncdu`**
```bash
$ ncdu -x /
--- / ---------------------------------------------------
   18.2GiB [##########] /var
    1.1GiB [          ] /usr
  240.0MiB [          ] /etc
   88.0MiB [          ] /home
    e   4.0KiB [          ]  lost+found
# press Enter to descend into /var, 'd' to delete a file, 'q' to quit
```

**7. Exporting an `ncdu` scan for offline/remote analysis**
```bash
$ ncdu -x -o /tmp/rootscan.ncdu /
# ... scan completes ...
$ scp server1:/tmp/rootscan.ncdu ./
$ ncdu -f rootscan.ncdu     # browse it later without re-scanning the live server
```

**8. Inode usage sanity check alongside block usage**
```bash
$ df -h /var
Filesystem                Size  Used Avail Use% Mounted on
/dev/mapper/vg_data-lv_var  20G   12G  7.0G  64% /var

$ df -i /var
Filesystem                  Inodes  IUsed   IFree IUse% Mounted on
/dev/mapper/vg_data-lv_var 1310720 1310000     720   99%  /var
# plenty of block space (64%), but inodes are nearly exhausted — different failure mode entirely
```

## Practice Questions

1. What's the fundamental difference in what `df` and `du` measure, and why can they report contradictory numbers for the same filesystem?
2. `df -h /app` shows 93% used, but `du -sh /app` only adds up to half that. What's the most likely cause, and how do you find and fix it without rebooting the server?
3. Write a one-liner to find the top 5 largest directories one level under `/var/log`, sorted largest first.
4. Why should you always pass `-x` to `du` (or `ncdu`) when scanning from `/`? What goes wrong if you don't?
5. What's the difference between `du`'s default output and `du --apparent-size`? Give an example of a file where the two would differ significantly.
6. A junior engineer says "`df` shows 100% used but there's no giant file anywhere I can find with `du`." What two things would you check?
7. Why might `df -h /` report less "Avail" space than "Size minus Used" suggests it should? (Hint: filesystem reserved blocks.)
8. How does `ncdu` help you resolve a disk-full incident faster than repeatedly running `du -h --max-depth=1`? What can you do directly inside `ncdu` that you can't with plain `du`?
9. You're on a locked-down production box where `ncdu` isn't installed and you can't install packages. What `du`/`sort` combination would you use instead to find the top space consumers?
10. `lsof +L1` shows a 34GB deleted-but-open file held by a Java process. Besides `kill`ing the process, what's a safer way to reclaim that space without dropping the service?

## Real Interview Questions (Company-Attributed)

- "`/var` partition is 90% full — what's your immediate action?" — asked at *an unnamed company (via community-sourced interview notes)*
- "In a folder structure in Linux, how do you check the size of a particular file/directory?" — asked at *Deloitte*

## Interview Key Points

- **`df` = filesystem/mount level, from kernel metadata; `du` = directory-tree walk, real file sizes.** State this distinction immediately when asked to differentiate them.
- The **#1 real-world "df vs du disagree" cause**: a large file was deleted while still open by a process (e.g., a runaway log), so the kernel hasn't freed the blocks yet. `lsof +L1` (or `lsof | grep deleted`) is the diagnostic command; fixing it means getting the process to close/reopen its file handle (graceful restart, `logrotate` with `copytruncate`, or signal to reopen logs).
- `du -x` and `ncdu -x` stay on one filesystem — essential when scanning from `/` to avoid crossing into NFS mounts, bind mounts, or pseudo-filesystems like `/proc`.
- `du --max-depth=N` combined with `sort -rh` is the standard "find the offender" workflow when `ncdu` isn't available.
- Reserved blocks (ext-family filesystems reserve ~5% for root by default, viewable/tunable via `tune2fs -l` / `tune2fs -m`) explain why `df` can show 100% used to a normal user with technically-free space still on disk.
- `ncdu` is preferred in live incident response because it's interactive — you see sizes and can delete directly, without repeated manual `du` invocations.
- Always mention `df -i` (inode usage) as a *separate* axis from `df` block usage — a filesystem can be nearly full on inodes while having plenty of free space, or vice versa (full deep dive in file 06).
