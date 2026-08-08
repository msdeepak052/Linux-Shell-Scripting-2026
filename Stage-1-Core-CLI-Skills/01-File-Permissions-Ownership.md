# File Permissions & Ownership: chmod, chown, chgrp

Every access-control decision on a Linux box ultimately comes down to these three commands — get them wrong on a shared server and you either lock yourself out or leave secrets world-readable.

## Explanation

### The rwx bits and the `ls -l` string

`ls -l` prints a 10-character string like `-rwxr-xr--`. Read it as: **1 file-type char + 3 groups of 3 permission chars**.

- Char 1: file type — `-` regular file, `d` directory, `l` symlink, `c`/`b` device, `s` socket, `p` pipe. This is *not* a permission bit; it's the single most common thing candidates misread.
- Chars 2-4: owner's `rwx`
- Chars 5-7: group's `rwx`
- Chars 8-10: other's `rwx`

`r` on a directory lets you list names inside it; `x` on a directory lets you `cd` into it or stat/traverse files inside it (even without `r`); `w` on a directory lets you create/delete/rename entries in it, regardless of the permissions on the files themselves. That last point trips people up: you can delete a file you don't own if you have write access to its parent directory (this is exactly what the sticky bit, covered below, is designed to prevent).

### Octal notation

Each digit is a sum: `read=4, write=2, execute=1`. Three digits = owner, group, other, in that fixed order.

| Octal | Symbolic | Typical use |
|---|---|---|
| `777` | `rwxrwxrwx` | almost never correct — full write access for everyone |
| `755` | `rwxr-xr-x` | executables, scripts, directories |
| `700` | `rwx------` | private executable/script, owner-only |
| `644` | `rw-r--r--` | ordinary files, configs meant to be read by others |
| `640` | `rw-r-----` | config/log with sensitive-but-group-readable data |
| `600` | `rw-------` | SSH private keys, credential files, owner-only secrets |

A leading 4th digit sets special bits: `4`=SUID, `2`=SGID, `1`=sticky (e.g. `2775` = SGID + `rwxrwxr-x`).

### Symbolic notation

Syntax: `chmod [who][op][perm] file`.

- **who**: `u` (user/owner), `g` (group), `o` (other), `a` (all — default if omitted, but omitting it also masks against umask on `-`/`+`, so be explicit)
- **op**: `+` add, `-` remove, `=` set exactly (clears anything not listed)
- **perm**: `r`, `w`, `x`, plus `s` (SUID/SGID) and `t` (sticky), and capital **`X`**

`X` only sets execute if the target is a directory, **or** already has execute set for *some* class. `chmod -R a+X /srv/data` is the safe way to make an entire tree traversable — directories get `x`, existing scripts keep their `x`, but plain data files that were never executable stay non-executable. `chmod -R a+x` on the same tree would make *every* file executable, which is almost always wrong.

### chmod -R gotchas

`chmod -R 755 /opt/myapp` is a classic junior mistake: it stamps `755` onto every file and directory alike, making config files, JSON/YAML, and log files executable — which is functionally harmless but a real problem for security audits, `find`-based malware scans, and least-privilege reviews. The fix is to treat directories and files differently:

```bash
$ find /opt/myapp -type d -exec chmod 755 {} \;
$ find /opt/myapp -type f -exec chmod 644 {} \;
$ find /opt/myapp -type f -name "*.sh" -exec chmod 755 {} \;
```

or use `chmod -R u+X` / `a+X` when you just want traversal restored without guessing at exact modes.

### chown / chgrp mechanics

- `chown alice file` — changes owner only, group untouched.
- `chown alice:devs file` — changes owner **and** group in one call.
- `chown :devs file` — changes group only, owner untouched. Exactly equivalent to `chgrp devs file`.
- `chown alice: file` — changes owner to `alice` **and** group to `alice`'s primary group (note the trailing colon with nothing after it).
- `chown -R` — recurse; same dir/file distinction concerns as `chmod -R` don't apply here since ownership isn't type-sensitive, but recursing across a mount boundary or symlink can still surprise you — use `--no-dereference` or check `-H`/`-L`/`-P` behavior if symlinks are involved.
- `chgrp` is a strict subset of `chown` — it only ever touches the group field, nothing else.

### Who can chmod/chown

- **chmod**: the file's **owner**, or **root**. Group members who aren't the owner cannot `chmod` a file just because they can write to it.
- **chown** (changing the *owner*): **root only**, always, on stock Linux. A non-root owner cannot give a file away to another user — POSIX calls this `_POSIX_CHOWN_RESTRICTED` and Linux enables it by default. The reason is practical, not paranoid: without this restriction a user could create a file under a disk quota, `chown` it to a victim, and dodge their own quota — or hand off a file with no trace of who actually created it.
- **chgrp** (or `chown :group`): a non-root owner *can* change the group, but only to a group they are themselves a member of — you can't hand a file to a group you don't belong to.

### Which one should you actually use? (Decision rule)

| Situation | Use | Why |
|---|---|---|
| Setting a known, absolute permission set from scratch | **Octal** | fastest to type, unambiguous, e.g. `chmod 644 file` — no doubt about the final state |
| Making one relative tweak without knowing/caring about the rest | **Symbolic** | `chmod +x script.sh`, `chmod g-w file` — doesn't require you to first check current bits |
| Applying a baseline across a fleet/CI pipeline, need it auditable | **Octal** | trivially diffable — `644` in a script means the same thing on every run |
| Toggling execute safely across a mixed file/dir tree | **Symbolic with `X`** | `chmod -R a+X` avoids accidentally making data files executable |

Bottom line: reach for octal when you're declaring the final permission state outright, and symbolic when you're nudging one bit without disturbing the rest.

## Hands-On Examples

A quick note before the first example: when you paste a multi-line construct like a `cat > file << EOF ... EOF` heredoc straight into an interactive shell, bash prints a `>` continuation prompt on each line automatically — that's bash telling you it's still reading input, not something you type yourself. The examples below show it exactly as your terminal would render it; if the same lines lived in a saved script file instead, there would be no `>` characters at all, just the raw content.

**1. Reading and decoding the permission string**
```bash
$ ls -l notes.txt
-rw-r--r-- 1 deepak deepak 128 Aug  8 09:12 notes.txt
```
`-` = regular file, owner `rw-` (6), group `r--` (4), other `r--` (4) → octal `644`.

**2. Same change, two notations**
```bash
$ chmod 640 notes.txt
$ ls -l notes.txt
-rw-r----- 1 deepak deepak 128 Aug  8 09:12 notes.txt

$ chmod o-r,g=r notes.txt
$ ls -l notes.txt
-rw-r----- 1 deepak deepak 128 Aug  8 09:12 notes.txt
```
Both land on the same `640` — octal set it in one shot, symbolic did it by removing other's read and pinning group to exactly `r`.

**3. Making a script executable without touching anything else**
```bash
$ ls -l deploy.sh
-rw-r--r-- 1 deepak deepak 512 Aug  8 09:20 deploy.sh
$ ./deploy.sh
bash: ./deploy.sh: Permission denied
$ chmod +x deploy.sh
$ ls -l deploy.sh
-rwxr-xr-x 1 deepak deepak 512 Aug  8 09:20 deploy.sh
```
`chmod +x` is the textbook case for symbolic mode: you don't need to know or care that it was `644` before.

**4. Securing an SSH private key**
```bash
$ ls -l ~/.ssh/id_rsa
-rw-r--r-- 1 deepak deepak 1823 Aug  8 09:30 /home/deepak/.ssh/id_rsa
$ ssh -i ~/.ssh/id_rsa svc-app@10.0.4.12
Permissions 0644 for '/home/deepak/.ssh/id_rsa' are too open.
It is required that your private key files are NOT accessible by others.
This private key will be ignored.

$ chmod 600 ~/.ssh/id_rsa
$ ls -l ~/.ssh/id_rsa
-rw------- 1 deepak deepak 1823 Aug  8 09:30 /home/deepak/.ssh/id_rsa
$ ssh -i ~/.ssh/id_rsa svc-app@10.0.4.12
svc-app@app-01:~$
```
SSH refuses to even try a key that's group/other readable — this is octal territory, `600` is a well-known absolute target.

**5. chown / chgrp variants**
```bash
$ ls -l report.csv
-rw-r--r-- 1 bob bob 4096 Aug  8 09:40 report.csv

$ sudo chown alice report.csv        # owner only
$ ls -l report.csv
-rw-r--r-- 1 alice bob 4096 Aug  8 09:40 report.csv

$ sudo chown :devs report.csv        # group only
$ ls -l report.csv
-rw-r--r-- 1 alice devs 4096 Aug  8 09:40 report.csv

$ sudo chown alice:devs report.csv   # both at once
$ chgrp devs report.csv              # equivalent to chown :devs
```
As a non-root user, `chown alice report.csv` on a file you own fails with `chown: changing ownership of 'report.csv': Operation not permitted` — giving files to another *user* is root-only, always.

**6. The `chmod -R` gotcha on a deployed app directory**
```bash
$ chmod -R 755 /opt/myapp        # "fixed" it... poorly
$ find /opt/myapp -maxdepth 1 -type f -exec ls -l {} \;
-rwxr-xr-x 1 svc-app svc-app  892 Aug  8 09:50 config.yaml
-rwxr-xr-x 1 svc-app svc-app 2048 Aug  8 09:50 app.jar

$ find /opt/myapp -type d -exec chmod 755 {} \;
$ find /opt/myapp -type f -exec chmod 644 {} \;
$ find /opt/myapp -type f -name "*.sh" -exec chmod 755 {} \;
$ ls -l /opt/myapp/config.yaml /opt/myapp/start.sh
-rw-r--r-- 1 svc-app svc-app  892 Aug  8 09:50 config.yaml
-rwxr-xr-x 1 svc-app svc-app  310 Aug  8 09:50 start.sh
```
`config.yaml` and `app.jar` had no business being executable — a split `find` pass restores sane, auditable permissions.

**7. Shared team directory with SGID**
```bash
$ sudo mkdir /srv/team-data
$ sudo chown deepak:devs /srv/team-data
$ sudo chmod 2775 /srv/team-data
$ ls -ld /srv/team-data
drwxrwsr-x 2 deepak devs 4096 Aug  8 10:05 /srv/team-data

$ su - alice
$ touch /srv/team-data/alice-notes.txt
$ ls -l /srv/team-data/alice-notes.txt
-rw-r--r-- 1 alice devs 0 Aug  8 10:07 alice-notes.txt
```
The `s` in `rwsr-x` is SGID: every new file `alice` creates inherits the `devs` group automatically, so nobody has to remember to `chgrp` after the fact.

**8. Production: fixing permissions and ownership together after a bad deploy**
```bash
$ ls -ld /opt/payments-api
drwxr-xr-x 6 root root 4096 Aug  8 08:00 /opt/payments-api
$ sudo systemctl status payments-api
● payments-api.service - Payments API
   Active: failed (Result: exit-code)
$ sudo journalctl -u payments-api -n 5
payments-api[9021]: FATAL: cannot open /opt/payments-api/secrets/db.env: Permission denied

$ sudo chown -R svc-payments:svc-payments /opt/payments-api
$ sudo find /opt/payments-api -type d -exec chmod 755 {} \;
$ sudo find /opt/payments-api -type f -exec chmod 644 {} \;
$ sudo chmod 640 /opt/payments-api/secrets/db.env
$ sudo systemctl restart payments-api
$ ls -l /opt/payments-api/secrets/db.env
-rw-r----- 1 svc-payments svc-payments 210 Aug  8 10:15 db.env
```
The deploy script had left everything owned by `root`; the service user couldn't read its own secrets. Fixing it takes both tools together: `chown -R` to hand the tree to the right service account, then a dir/file-aware `chmod` pass, with the secrets file pinned tighter than the rest.

## Practice Questions

1. A teammate's `deploy.sh` is `rw-r--r--`. What's the fastest single command to make it executable without changing anything else, and why is symbolic mode the better tool here?
2. `ssh -i id_rsa user@host` says the key is "too open" even though you're the only account on your laptop. What command fixes it, and what exact octal mode does SSH expect?
3. You're logged in as `bob`, and `report.csv` is owned by `bob:bob`. You run `chown alice report.csv` and it fails. Why, and what's the actual fix?
4. A junior engineer runs `chmod -R 755 /opt/myapp` on a directory containing configs, a jar, and shell scripts to "fix a permissions issue." What's wrong with this approach, and how would you redo it correctly?
5. Explain the difference between `chown alice:devs file`, `chown alice: file`, and `chown :devs file` — what does each one actually touch?
6. What does `chmod g+s /srv/team-data` accomplish, and why would a platform team prefer it over asking everyone to remember `chgrp devs newfile.txt` after every file they create?
7. Why does `chmod -R a+X /srv/data` behave differently from `chmod -R a+x /srv/data` on a tree that mixes shell scripts with plain data files?
8. You find a database credentials file sitting at `644` when it should be `640`. What single octal command fixes it, and why is octal the better choice here over `chmod o-r`?
9. A colleague suggests `chmod 777` as a quick fix for a recurring "Permission denied" error in a production service. What's wrong with that as a habit, and what would you actually check first (hint: think about the parent directories, the service's running user, and group membership)?
10. What POSIX mechanism stops a regular user from bypassing their disk quota by `chown`-ing a file they created to someone else's account, and why is that restricted to root rather than just the file owner?

## Real Interview Questions (Company-Attributed)

- "What types of file permissions exist in Linux?" — asked at *TCS*
- "What is the command to change file permissions in Linux?" — asked at *ZopSmart*

## Interview Key Points

- The leading character in `ls -l`'s 10-char string is file type, not a permission bit — misreading `-rwxr-xr-x` as "10 permission bits" is a common tell that a candidate hasn't internalized the format.
- `chmod -R` doesn't distinguish files from directories — blindly stamping `755` or `644` across a whole tree is a red flag; the fix is `find -type d`/`find -type f` split, or `chmod -R u+X`/`a+X` when you just need traversal restored.
- Changing a file's **owner** is root-only, full stop, even for the file's current owner — this is `_POSIX_CHOWN_RESTRICTED`, and it exists to stop quota-dodging and ownership-laundering, not just "because Linux says so."
- Changing a file's **group** (`chgrp` / `chown :group`) is allowed for non-root users, but only to a group they already belong to.
- SGID (`chmod g+s dir`, or the `2` in `2775`) on a shared directory makes every new file inherit the directory's group automatically — the standard, low-maintenance pattern for team-shared storage, versus expecting everyone to `chgrp` by hand.
- Octal vs. symbolic isn't a style preference: octal declares an absolute end state (good for baselines, CI, security audits); symbolic makes a relative change without needing or risking the current bits (good for one-off tweaks like `+x`).
- Capital `X` vs. lowercase `x` in symbolic mode is an underused but real differentiator — `X` only grants execute to directories or things already executable somewhere, making `chmod -R a+X` safe on mixed trees where `a+x` would not be.
- `chmod 777` as a reflexive fix is a smell interviewers listen for — a strong answer diagnoses first (owning user/group of the process, parent directory `x` bits, actual error from logs) instead of nuking the mode bits.
