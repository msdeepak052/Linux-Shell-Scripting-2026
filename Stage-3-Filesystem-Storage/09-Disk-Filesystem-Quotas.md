# Disk/Filesystem Quotas: `quotacheck`, `edquota`, `repquota`

Filesystem quotas enforce per-user or per-group limits on disk space and/or inode count, preventing any one account from starving shared storage — a classic multi-tenant server control.

## Explanation

**What quotas control**: two independent limits, both settable per-user or per-group:
- **Block quota** — total disk space (KB/blocks) an entity can consume.
- **Inode quota** — total number of files/directories an entity can own (protects against the many-small-files inode exhaustion problem from a single user, see file 06).

**Soft vs hard limits**:
- **Soft limit** — can be exceeded temporarily, for a **grace period** (default 7 days). Warnings are issued but writes still succeed.
- **Hard limit** — an absolute ceiling; once hit, further writes fail immediately with "Disk quota exceeded," and once a soft limit's grace period expires, it effectively becomes enforced like a hard limit until usage drops back under the soft limit.

**Setup workflow**:
1. Filesystem must be mounted with quota support: `usrquota`/`grpquota` options in `/etc/fstab` (ext4) — XFS uses `uquota`/`gquota`/`pquota` (project quotas) mount options instead and manages quotas somewhat differently (`xfs_quota` command rather than the classic quota tools, though `repquota`/`edquota` can still interoperate on some setups).
2. Remount/reboot so the mount options take effect.
3. `quotacheck -cug /mountpoint` — scans the filesystem and creates the initial `aquota.user` / `aquota.group` accounting files (must typically run with the filesystem quiescent, or on ext4 with journal-aware quotacheck).
4. `quotaon /mountpoint` — activates enforcement.
5. `edquota -u username` — opens an editor to set soft/hard limits for a user (or `edquota -g groupname` for a group).
6. `repquota /mountpoint` — reports current usage vs limits for all users/groups on that filesystem.

**Key commands reference**:
```
quotacheck -cug /home        # -c create, -u user, -g group: (re)initialize quota accounting files
quotaon -v /home              # enable quota enforcement, verbose
quotaoff -v /home             # disable enforcement
edquota -u alice               # interactively edit alice's block/inode soft & hard limits
edquota -t                     # set grace period(s) for all filesystems
repquota -a                    # report quota usage for all quota-enabled filesystems
repquota -u /home              # report just user quotas on /home
quota -u alice                 # show alice's own usage/limits (what a user runs on themselves)
setquota -u alice 5G 6G 10000 12000 /home   # non-interactive: block-soft block-hard inode-soft inode-hard
```

**XFS variant** (project quotas, more modern approach, no per-directory `quotacheck` needed since XFS tracks quotas from mount):
```
mount -o uquota,gquota,pquota /dev/sdb1 /data
xfs_quota -x -c 'limit bsoft=5g bhard=6g isoft=10000 ihard=12000 alice' /data
xfs_quota -x -c report /data
```

**Gotchas**:
- Quotas apply **per filesystem**, not per directory — you can't quota-limit `/home/alice` unless `/home` (or wherever alice's directory sits) is its own mounted filesystem/LV with quota enabled.
- Root/superuser is typically exempt from quota enforcement by default.
- `quotacheck` ideally runs on an unmounted or read-only filesystem for full accuracy; running it on a live, heavily-written filesystem can produce a slightly inconsistent initial count (usually self-corrects as usage is tracked going forward).
- Forgetting to re-add `usrquota`/`grpquota` to `/etc/fstab` after a remount/reboot silently disables enforcement even though the accounting files still exist.
- Hitting a hard limit gives an application-visible **`EDQUOT`** error (distinct from `ENOSPC` for genuine full disks) — application logs may show "Disk quota exceeded" specifically, a useful diagnostic clue distinguishing "this user is over quota" from "the filesystem is actually full."

## Hands-On Examples

**1. Enabling quota support in `/etc/fstab`**
```bash
$ grep /home /etc/fstab
/dev/mapper/vg_data-lv_home /home ext4 defaults,usrquota,grpquota 0 2

$ mount -o remount /home
$ mount | grep /home
/dev/mapper/vg_data-lv_home on /home type ext4 (rw,relatime,quota,usrquota,grpquota)
```

**2. Initializing quota accounting files**
```bash
$ quotacheck -cug /home
quotacheck: Scanning /dev/mapper/vg_data-lv_home [/home] done
quotacheck: Checked 4218 directories and 51032 files

$ ls -la /home/aquota.*
-rw------- 1 root root 7168 Aug  8 10:20 /home/aquota.group
-rw------- 1 root root 7168 Aug  8 10:20 /home/aquota.user
```

**3. Turning enforcement on**
```bash
$ quotaon -v /home
/dev/mapper/vg_data-lv_home [/home]: user quotas turned on
/dev/mapper/vg_data-lv_home [/home]: group quotas turned on
```

**4. Setting a user's quota interactively**
```bash
$ edquota -u alice
# opens $EDITOR with:
Disk quotas for user alice (uid 1001):
  Filesystem  blocks  soft   hard   inodes  soft   hard
  /dev/mapper/vg_data-lv_home  1048576  5242880  6291456  8500  10000  12000
# blocks are in KB: soft=5G, hard=6G; inodes: soft=10000, hard=12000
```

**5. Setting a quota non-interactively (scriptable, e.g. onboarding automation)**
```bash
$ setquota -u bob 5G 6G 10000 12000 /home
$ quota -u bob
Disk quotas for user bob (uid 1002):
     Filesystem  blocks   quota   limit   grace   files   quota   limit   grace
     /dev/mapper/vg_data-lv_home
                 120000  5242880 6291456          842   10000   12000
```

**6. Reporting usage across all users**
```bash
$ repquota -a
*** Report for user quotas on device /dev/mapper/vg_data-lv_home
Block grace time: 7days; Inode grace time: 7days
                        Block limits                File limits
User            used    soft    hard  grace    used  soft  hard  grace
----------------------------------------------------------------------
root      --  1048     0       0             120     0     0
alice     --  4980000  5242880 6291456        8100   10000 12000
bob       +-  6291500  5242880 6291456  6days   9800   10000 12000
```
Note bob's `+-`: block usage is over the hard limit (shouldn't normally be possible except via legacy data before quota was enabled, or root-written files), and the grace column shows time remaining before soft-limit enforcement kicks in for the flagged dimension.

**7. What a user sees when they hit a hard limit**
```bash
$ su - bob
$ dd if=/dev/zero of=/home/bob/bigfile bs=1M count=2000
dd: error writing '/home/bob/bigfile': Disk quota exceeded
1500+0 records in
1499+0 records out
1572864000 bytes (1.6 GB) copied

$ quota -u bob
Disk quotas for user bob (uid 1002):
     Filesystem  blocks   quota   limit   grace   files  quota  limit  grace
     /dev/mapper/vg_data-lv_home
               *6291456* 5242880 6291456  6days    9950  10000  12000
# asterisk flags the entity as currently AT/OVER its limit
```

**8. XFS project quota equivalent (modern filesystems)**
```bash
$ mount -o remount,uquota,gquota /data
$ xfs_quota -x -c 'limit bsoft=5g bhard=6g isoft=10000 ihard=12000 alice' /data
$ xfs_quota -x -c 'report -u' /data
User quota on /data (/dev/sdb1)
                        Blocks
User ID      Used   Soft   Hard Warn/Grace
alice      4980000 5242880 6291456  00 [--------]
```

## Practice Questions

1. What's the difference between a soft limit and a hard limit, and what happens to a user who's over their soft limit but the grace period hasn't expired yet?
2. Walk through the full setup sequence, from `/etc/fstab` edit to a working, enforced per-user quota on `/home`.
3. Why must the filesystem have `usrquota`/`grpquota` mount options before `quotacheck` will work? What happens if you skip that step?
4. A user's app is failing with write errors. `df -h` shows the filesystem at 60% used. What's the second thing you'd check (besides `df -i`), given this file's topic, and what command reveals it?
5. What's the practical difference in error a user sees hitting a quota hard limit (`EDQUOT`) versus a genuinely full filesystem (`ENOSPC`)? Why does distinguishing them matter operationally?
6. Can you apply a quota to a single subdirectory like `/home/alice` if `/home` is one big shared filesystem with many users? Why or why not, and what would you need to change to make per-subdirectory limits work?
7. Write the non-interactive `setquota` command to give user `carol` a 10G soft / 12G hard block limit and 20000/25000 soft/hard inode limits on `/data`.
8. How does quota setup differ on XFS compared to ext4 — what mount options and command (`xfs_quota` vs `edquota`/`quotacheck`) does each use?
9. `repquota -a` shows a user flagged with `+-` and a grace countdown. What does that notation mean, and what happens to that user's writes once the grace period hits zero?
10. Is root subject to quota limits by default? Why does that matter when troubleshooting "quota says X but usage looks different" discrepancies caused by root-owned files?

## Real Interview Questions (Company-Attributed)

- "How do you ensure five different application teams don't use more than a particular amount of disk space?" — asked at *Amadeus Labs*

## Interview Key Points

- **Quotas are per-filesystem, not per-directory** — a very common trap; you can't quota-limit an arbitrary directory unless it's its own mount point (which is exactly why quota-managed home directories are often on their own LV).
- Know the **soft vs hard limit** distinction cold: soft = warning + grace period before enforcement, hard = absolute immediate ceiling. Both apply independently to blocks (space) and inodes (file count).
- The setup sequence is a common practical/whiteboard question: `fstab` mount options (`usrquota`/`grpquota`) → remount → `quotacheck -cug` → `quotaon` → `edquota`/`setquota` → `repquota` to verify.
- `EDQUOT` ("Disk quota exceeded") vs `ENOSPC` ("No space left on device") are **distinct kernel errors** — being able to tell an interviewer that a specific user hitting their quota looks different in application logs than an actually-full filesystem shows real depth.
- XFS uses its own quota model (`uquota`/`gquota`/`pquota` mount options and the `xfs_quota` tool) rather than the classic `quotacheck`/`edquota` ext4 toolchain — mention this distinction if asked to compare filesystems.
- Root is exempt from quotas by default — relevant when usage numbers look inconsistent (root-owned files don't count against a user's quota even if placed in their home directory).
- Inode quotas exist specifically to prevent the inode-exhaustion scenario (file 06) being caused by a single misbehaving user/account, not just space hogging — tie these two topics together if asked "why would you set an inode quota, not just a space quota."
- `repquota -a` / `quota -u <user>` are the two go-to commands for auditing — know both the admin-wide view and the per-user self-check view.
