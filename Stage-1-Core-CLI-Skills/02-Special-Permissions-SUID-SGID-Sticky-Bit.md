# Special Permissions: SUID, SGID, Sticky Bit

Three extra permission bits that override the normal owner/group/other model — the mechanism behind privilege elevation tools like `passwd`, shared team directories, and public temp-dir hygiene, and a favorite privilege-escalation attack surface.

## Explanation

Standard Unix permissions (`rwx` for owner/group/other) answer "what can this identity do to this file." SUID, SGID, and the sticky bit are a fourth, separate set of bits that change *whose identity a program runs as* or *how a directory enforces ownership rules*. They live in the same `mode` field as the normal permission bits but occupy a higher octal digit, so `chmod` accepts a 4-digit form (`4755`, `2775`, `1777`) where the leading digit is the special-bits mask.

### SUID (Set User ID) — octal 4000

Set on an **executable file**, SUID makes the kernel run the process with the **effective UID of the file's owner**, not the UID of the user who launched it. This is how `/usr/bin/passwd` — owned by `root`, mode `-rwsr-xr-x` — lets an unprivileged user overwrite their own entry in `/etc/shadow` (a file only root can write): the process briefly *is* root for the duration of the write, then exits. SUID on a directory does nothing — the bit is simply ignored for that purpose.

Modern Linux kernels **ignore the SUID bit on scripts** (anything starting with `#!`) for security reasons — there's a well-known TOCTOU race between the kernel reading the shebang and exec'ing the interpreter that made SUID shell/Python scripts trivially exploitable, so the kernel silently drops the privilege elevation for interpreted scripts. SUID only reliably elevates privileges for **compiled binaries**. This is a genuine, frequently-tested nuance — "make a SUID bash script" is a classic broken assumption.

### SGID (Set Group ID) — octal 2000

On an **executable file**, SGID is SUID's sibling: the process runs with the **effective GID of the file's group** instead of the invoking user's primary group.

On a **directory**, SGID means something different and more commonly used in production: any file or subdirectory created inside inherits the **directory's group ownership**, not the creating user's primary group — and subdirectories created inside also inherit the SGID bit itself, so the behavior propagates recursively. This is the standard mechanism for shared team directories (e.g. `/srv/team-data`) where multiple users with different primary groups need every file they create to end up owned by a common team group, without everyone remembering to `chgrp` or `newgrp` manually.

### Sticky Bit — octal 1000

Historically (old Unix/BSD), setting the sticky bit on an executable told the kernel to keep its text segment resident in swap for faster reload — this meaning is obsolete on Linux and worth mentioning only as trivia; it has **no effect on regular files** on modern Linux.

On a **directory**, the sticky bit restricts *deletion and renaming*: even if a directory is world-writable (`drwxrwxrwx`), a user can only delete or rename files inside it if they are the **file's owner**, the **directory's owner**, or **root** — normal Unix rules would otherwise let anyone with write access to the directory delete any file inside it regardless of who owns the file. The canonical example is `/tmp`, mode `drwxrwxrwt`: everyone can create files there, but nobody can delete another user's files, which is exactly the property a shared scratch directory needs.

### The `ls -l` capitalization gotcha (s vs S, t vs T)

`ls -l` overlays the special bit onto the execute-bit column it corresponds to:

| State | Owner-exec column shows | Meaning |
|---|---|---|
| SUID set + owner has `x` | `s` (lowercase) | SUID active and meaningful |
| SUID set, owner lacks `x` | `S` (uppercase) | SUID set but has **no effect** — nothing to elevate into |
| SGID set + group has `x` | `s` (lowercase, group column) | SGID active |
| SGID set, group lacks `x` | `S` (uppercase, group column) | SGID set but meaningless (on a file; on a directory SGID's inheritance effect works regardless of the `x` bit) |
| Sticky set + other has `x` | `t` (lowercase, other column) | Sticky active (normal on directories) |
| Sticky set, other lacks `x` | `T` (uppercase, other column) | Sticky set but "wasted" |

The rule to internalize: **uppercase always means "the special bit is configured but the execute bit it depends on is missing, so it's a no-op."** This is one of the single most commonly asked "read this `ls -l` output" trap questions in Linux interviews — interviewers will show you `-rwSr--r--` and ask what's wrong with it.

### Symbolic vs. octal notation

| Bit | Symbolic (set) | Symbolic (unset) | Octal digit |
|---|---|---|---|
| SUID | `chmod u+s file` | `chmod u-s file` | `4` (e.g. `4755`) |
| SGID | `chmod g+s dir` | `chmod g-s dir` | `2` (e.g. `2775`) |
| Sticky | `chmod +t dir` (or `o+t`) | `chmod -t dir` | `1` (e.g. `1777`) |

The octal form is always **4 digits** when special bits are involved — `4755` means SUID + `rwxr-xr-x`; `2775` means SGID + `rwxrwxr-x`; `1777` means sticky + `rwxrwxrwx`. You can combine bits, e.g. `6755` sets both SUID and SGID.

### Security angle

SUID/SGID root binaries are a textbook privilege-escalation vector: if such a binary has a bug (buffer overflow, unsanitized shell-out, path injection) or was left writable, any local user can potentially leverage it to gain root. Standard security-audit practice is to periodically enumerate every SUID/SGID binary on a system and diff it against a known-good baseline, since attackers who gain any foothold often plant a SUID shell (`cp /bin/bash /tmp/.hidden; chmod 4755 /tmp/.hidden`) for persistent, silent privilege escalation. A world-writable SUID binary is especially dangerous — anyone can replace its contents with arbitrary code that then runs as the file's (often root) owner.

### SUID vs SGID vs Sticky Bit — quick comparison

| | On a regular file | On a directory | Octal | Real-world example |
|---|---|---|---|---|
| **SUID** | Runs as the **file owner's** UID | No effect (ignored) | `4000` | `/usr/bin/passwd` (root-owned, lets users edit `/etc/shadow`) |
| **SGID** | Runs as the **file group's** GID | New files/dirs created inside **inherit the directory's group** | `2000` | `/srv/team-data` shared project directory |
| **Sticky** | No effect (obsolete historical meaning only) | Only the **file owner, dir owner, or root** can delete/rename files inside | `1000` | `/tmp` (`drwxrwxrwt`) |

## Hands-On Examples

**1. Setting SUID on a test binary and observing `ls -l`**
```bash
$ cp /bin/cat /home/deepak/testcat
$ sudo chown root:root /home/deepak/testcat
$ ls -l /home/deepak/testcat
-rwxr-xr-x 1 root root 35080 Aug  8 09:12 /home/deepak/testcat

$ sudo chmod u+s /home/deepak/testcat
$ ls -l /home/deepak/testcat
-rwsr-xr-x 1 root root 35080 Aug  8 09:12 /home/deepak/testcat
```
Lowercase `s` in the owner-execute slot: SUID is set and the owner-execute bit is also set, so it's active. Running `./testcat somefile` now executes with root's effective UID (though `cat` itself doesn't do anything privileged with that, unlike `passwd`).

**2. The real-world reference case: `/usr/bin/passwd`**
```bash
$ ls -l /usr/bin/passwd
-rwsr-xr-x 1 root root 68208 Mar  2  2026 /usr/bin/passwd

$ whoami
deepak
$ passwd
Changing password for deepak.
Current password:
New password:
Retype new password:
passwd: password updated successfully

$ ls -l /etc/shadow
-rw-r----- 1 root shadow 1428 Aug  8 09:15 /etc/shadow
```
`deepak` has no write access to `/etc/shadow` directly, yet `passwd` succeeded — because while `passwd` runs, its effective UID is `root` (SUID), not `deepak`.

**3. SGID on an executable (rare, but testable)**
```bash
$ sudo chmod g+s /home/deepak/testcat
$ ls -l /home/deepak/testcat
-rwsr-sr-x 1 root root 35080 Aug  8 09:20 /home/deepak/testcat
```
Both SUID (`s` in owner slot) and SGID (`s` in group slot) are now set — `6755` in octal.

**4. Demonstrating the `s` vs `S` gotcha explicitly**
```bash
$ sudo chmod 4644 /home/deepak/testcat     # SUID set, but owner-exec bit removed
$ ls -l /home/deepak/testcat
-rwSr--r-- 1 root root 35080 Aug  8 09:24 /home/deepak/testcat
```
Capital `S`: SUID is technically set in the mode bits, but since owner has no execute permission at all, there's no process to run with elevated privileges — the bit is inert. Restoring execute flips it back to lowercase:
```bash
$ sudo chmod u+x /home/deepak/testcat
$ ls -l /home/deepak/testcat
-rwsr--r-- 1 root root 35080 Aug  8 09:25 /home/deepak/testcat
```

**5. Setting up a shared SGID team directory**
```bash
$ sudo mkdir -p /srv/team-data
$ sudo groupadd platform-team
$ sudo usermod -aG platform-team deepak
$ sudo usermod -aG platform-team asha
$ sudo chown root:platform-team /srv/team-data
$ sudo chmod 2775 /srv/team-data
$ ls -ld /srv/team-data
drwxrwsr-x 2 root platform-team 4096 Aug  8 09:30 /srv/team-data
```
Note the `s` in the group-execute column of a directory — this is SGID working as inheritance, not as "run as group," since directories aren't executed.
```bash
$ su - asha
asha@platform-01:~$ touch /srv/team-data/report.csv
asha@platform-01:~$ ls -l /srv/team-data/report.csv
-rw-r--r-- 1 asha platform-team 0 Aug  8 09:31 report.csv
```
`asha`'s primary group is `asha`, but `report.csv` came out owned by group `platform-team` — inherited from the parent directory, not from `asha`'s own group. Without SGID, it would have been `-rw-r--r-- 1 asha asha ...` and unreadable/unwritable by teammates unless `umask` and group membership happened to line up.

**6. Sticky bit on a shared scratch directory**
```bash
$ sudo mkdir /srv/scratch
$ sudo chmod 1777 /srv/scratch
$ ls -ld /srv/scratch
drwxrwxrwt 2 root root 4096 Aug  8 09:35 /srv/scratch

$ su - asha
asha@platform-01:~$ touch /srv/scratch/asha-notes.txt
asha@platform-01:~$ exit
$ su - deepak
deepak@platform-01:~$ rm /srv/scratch/asha-notes.txt
rm: cannot remove '/srv/scratch/asha-notes.txt': Operation not permitted
```
Even though `/srv/scratch` is world-writable (anyone can create files), `deepak` can't delete `asha`'s file — only `asha`, `root`, or the directory owner (`root`) can. This is exactly how `/tmp` behaves:
```bash
$ ls -ld /tmp
drwxrwxrwt 15 root root 4096 Aug  8 09:00 /tmp
```

**7. Auditing a system for SUID/SGID binaries (security review)**
```bash
$ sudo find / -xdev -perm -4000 -type f -exec ls -l {} \; 2>/dev/null
-rwsr-xr-x 1 root root  68208 Mar  2  2026 /usr/bin/passwd
-rwsr-xr-x 1 root root  55528 Feb 14  2026 /usr/bin/sudo
-rwsr-xr-x 1 root root  35152 Jan 30  2026 /usr/bin/su
-rwsr-xr-x 1 root root  44784 Feb  2  2026 /usr/bin/mount
-rwsr-xr-x 1 root root  35080 Aug  8 09:24 /home/deepak/testcat   # <-- flagged: not a stock binary

$ sudo find / -xdev -perm -2000 -type f -exec ls -l {} \; 2>/dev/null
-rwxr-sr-x 1 root utmp 18848 Feb  2  2026 /usr/bin/wall
-rwxr-sr-x 1 root crontab 39344 Jan 30  2026 /usr/bin/crontab
```
`testcat` shows up because we made it earlier in example 1 — in a real audit, any SUID/SGID binary outside the OS package baseline (verified against `dpkg -V` / `rpm -Va`, or a known-good inventory) is a red flag worth investigating immediately; attackers commonly drop `cp /bin/bash /tmp/.x; chmod 4755 /tmp/.x` for persistence.

**8. Finding world-writable SUID files — the especially dangerous combination**
```bash
$ sudo find / -xdev -perm -4002 -type f 2>/dev/null
/opt/legacy-app/bin/run-as-service
```
`-perm -4002` matches SUID *and* world-writable (`--- --- -w-`). Any local user can overwrite `run-as-service`'s contents with arbitrary code that then executes as its owner — this combination should never exist on a hardened system and is an automatic finding in any security review.

## Practice Questions

1. You run `ls -l /usr/bin/passwd` and see `-rwsr-xr-x`. Explain in your own words what happens, privilege-wise, from the moment a regular user types `passwd` to the moment `/etc/shadow` gets updated.
2. What does `chmod 2775 /srv/team-data` actually change about files created inside that directory afterward — and what does it *not* change about files already inside it before you ran the command?
3. You see `-rwSr--r--` on a file. What's wrong, and what single command would you run to make the SUID bit actually take effect?
4. A colleague tries to make a "quick admin script" SUID root with `chmod 4755 backup.sh` where `backup.sh` starts with `#!/bin/bash`. Will this achieve privilege elevation when a normal user runs it? Explain why or why not.
5. Why does `/tmp` need the sticky bit at all — what specific bad behavior would occur without it, given that `/tmp` is `drwxrwxrwx`-writable by everyone?
6. Write the `find` command(s) you'd run during a security audit to list every SUID binary on the filesystem, and explain why you'd add `2>/dev/null`.
7. What's the difference between SGID on a file versus SGID on a directory — many candidates conflate these, so be precise about both.
8. You `chmod 1777` a directory but a teammate reports they can still delete other people's files inside it. What are two possible explanations you'd check first (hint: think about who owns the directory, and what `ls -ld` actually shows)?
9. Design the exact sequence of commands to create `/srv/finance-reports` such that: it's owned by group `finance`, every new file created inside automatically belongs to group `finance` regardless of who creates it, and members can't delete each other's files.
10. During an incident response, you find `-rwsr-xr-x 1 root root 1113504 Aug  8 03:14 /var/tmp/.cache/systemd-helper` — a file that isn't part of any installed package. What does the SUID bit tell you about the risk here, and what would be your first three response actions?

## Interview Key Points

- **SUID = run as file owner; SGID on a file = run as file group; SGID on a directory = new children inherit the directory's group** — the SGID file-vs-directory distinction is the single most conflated fact on this topic; state both explicitly.
- **Uppercase `S`/`T` means the special bit is set but inert** because the underlying execute bit is missing — the classic "spot the gotcha in `ls -l` output" question; always connect it back to *why* (nothing to run/elevate without execute).
- **Linux ignores SUID on shebang scripts** (kernel-level, due to a historical TOCTOU exploit) — SUID for privilege elevation only reliably works on compiled binaries; a candidate who says "just SUID my bash script" reveals a gap.
- **SUID/SGID binaries are a standard privilege-escalation attack surface** — know the audit command `find / -perm -4000 -type f 2>/dev/null` (and the `-2000` / combined `/6000` variants) cold, and know that a world-writable SUID binary (`-perm -4002`) is an automatic critical finding.
- **Sticky bit only matters on directories in modern Linux**; its historical "keep program in swap" meaning on regular files is dead — don't over-explain the historical trivia, just acknowledge it exists.
- **`/tmp` (`drwxrwxrwt`) and shared team directories (`SGID` + group ownership) are the two production patterns interviewers expect you to design on the spot** — be ready to write the full `mkdir`/`chown`/`chmod` sequence from memory.
- Octal special-bit chmod is always a **4-digit** number (`4755`, `2775`, `1777`, or combined `6755`) — the leading digit is the special-bits mask, distinct from the usual 3-digit `rwx` form.
- The sticky bit's actual security property is narrow and precise: it restricts **deletion/renaming**, not creation or reading — a world-writable-plus-sticky directory still lets anyone create and read files, it just protects existing files from being removed by non-owners.
