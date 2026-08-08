# Umask & Default Permission Behavior

How the kernel decides the permissions a *newly created* file or directory gets before you ever run `chmod` — and why it's bitwise math, not subtraction.

## Explanation

### The base permissions before umask ever touches them

Every process that creates a file or directory requests a permission mode. In practice, the two creating syscalls use fixed maximums:
- **Regular files: 666** (`rw-rw-rw-`) — no execute bit, ever, at creation time. `open()`/`creat()` never set the execute bit regardless of umask; you must add it explicitly afterward with `chmod +x`. This is why a freshly created `.sh` file is never runnable via `./script.sh` even if `umask` is `000`.
- **Directories: 777** (`rwxrwxrwx`) — directories need the execute bit to be traversable/`cd`-able, so the OS requests it by default; umask then trims it down like any other bit.

umask never *adds* bits. It can only remove bits from these two ceilings. That asymmetry (666 vs 777) is the root of "why do my new files never have +x."

### It's bitwise AND-NOT, not subtraction

The formula is:

```
final_permission = requested_permission AND (NOT umask)
```

Most people mentally do `666 - umask` and get away with it for common values like `022`, `002`, `077` — but that's a coincidence of those specific masks, not how the kernel actually computes it. The real operation is bit-by-bit: take the complement (bitwise NOT) of the umask, then AND it against the base permission.

Worked example — `umask 022` on a new **file**:

```
base (666)      = 110 110 110
umask (022)     = 000 010 010
NOT umask       = 111 101 101   (this is what umask -S actually displays)
result = base AND NOT(umask)
  110 110 110
& 111 101 101
------------- 
  110 100 100   = 644 = rw-r--r--
```

Same umask on a new **directory** (base 777):

```
base (777)      = 111 111 111
NOT umask (022) = 111 101 101
& ------------- 
  111 101 101   = 755 = rwxr-xr-x
```

Why the distinction matters beyond trivia: subtraction and AND-NOT only diverge when the umask has a bit set that the base permission *doesn't* have, or in mixed cases with unusual masks (e.g. reasoning about `umask 077` combined with a program that explicitly `open()`s with mode `0741` — subtraction would give nonsense like negative digits; AND-NOT never can, because it's a bitwise clear operation, not arithmetic). Interviewers who ask you to compute an *uncommon* umask value are specifically checking whether you know it's AND-NOT.

### Common umask values

| umask | Files (666 base) | Dirs (777 base) | Typical use |
|---|---|---|---|
| `022` | `644` rw-r--r-- | `755` rwxr-xr-x | Default on most distros / root — owner writes, everyone reads |
| `002` | `664` rw-rw-r-- | `775` rwxrwxr-x | Group-collaborative setups (shared project dirs, some Debian group configs) |
| `077` | `600` rw------- | `700` rwx------ | Private/restrictive — home dirs, SSH key directories, secrets |
| `027` | `640` rw-r----- | `750` rwxr-x--- | Group-readable but no world access — common hardened default |

### Where umask lives, and inheritance

- **Session-only**: typing `umask 027` at a shell prompt affects that shell and anything it spawns from that point forward, until the shell exits. Not persistent.
- **Persistent, per-user**: `~/.bashrc`, `~/.profile`, `~/.bash_profile`.
- **Persistent, system-wide**: `/etc/profile`, `/etc/bash.bashrc`, and critically `/etc/login.defs` (`UMASK` directive) which sets the default for logins that go through `login`/`su`. Many distros also drive this via PAM's `pam_umask` module, which can read a per-user umask from `/etc/login.defs`, `/etc/default/login`, or the user's GECOS field.
- **Inheritance**: umask is a per-process attribute inherited from parent to child at `fork()`/`exec()` — a login shell's umask propagates to every command and subshell it launches, unless something along the way explicitly calls `umask` again.
- **systemd services are independent**: a `.service` unit does **not** inherit the interactive shell's umask by default — it starts with a systemd-wide default (typically `022`) unless you set `UMask=` explicitly in the unit file. This trips people up constantly: "I set `umask 077` in `.bashrc` but my systemd-launched app still writes world-readable files."

### Reading umask correctly (mental model)

Two different display modes, and they're **inverted** relative to each other:
- `umask` (no args) → prints the raw octal **mask being subtracted**, e.g. `0022`. This is "bits being cleared."
- `umask -S` → prints the **resulting allowed permissions** in symbolic form, e.g. `u=rwx,g=rx,o=rx`. This is NOT the mask — it's what's left over *after* applying the mask to 777/666. People misread `umask -S` as "the umask value" when it's actually the complement, already applied conceptually.

### umask has zero retroactive effect

umask only influences the *moment of creation* for a file or directory — it is consulted once, at `open()`/`mkdir()` time. It never touches files that already exist. This is a classic gotcha: "I changed umask to 077 but my old files in this directory are still world-readable at 644" — because umask wasn't in effect when those files were created, and changing it now does nothing to them. Fixing existing files requires `chmod` (or `chmod -R`), not a umask change.

## Hands-On Examples

**1. Check the current umask, both forms**
```bash
$ umask
0022

$ umask -S
u=rwx,g=rx,o=rx
```

**2. Create a file and directory with the default umask (022)**
```bash
$ touch report.txt
$ mkdir builds

$ ls -l report.txt
-rw-r--r-- 1 deepak deepak    0 Aug  8 10:02 report.txt

$ ls -ld builds
drwxr-xr-x 2 deepak deepak 4096 Aug  8 10:02 builds
```

**3. Change umask for the session and observe the effect**
```bash
$ umask 077
$ touch secret.key
$ mkdir private_dir

$ ls -l secret.key
-rw------- 1 deepak deepak    0 Aug  8 10:05 secret.key

$ ls -ld private_dir
drwx------ 2 deepak deepak 4096 Aug  8 10:05 private_dir
```

**4. Group-collaborative umask (002)**
```bash
$ umask 002
$ touch shared_notes.md
$ mkdir team_data

$ ls -l shared_notes.md
-rw-rw-r-- 1 deepak devteam    0 Aug  8 10:07 shared_notes.md

$ ls -ld team_data
drwxrwxr-x 2 deepak devteam 4096 Aug  8 10:07 team_data
```

**5. Confirming files never get default execute, regardless of umask**
```bash
$ umask 000
$ touch nofilter.sh
$ ls -l nofilter.sh
-rw-rw-rw- 1 deepak deepak    0 Aug  8 10:09 nofilter.sh
# no x bit anywhere, even with umask 000 — must chmod +x explicitly
$ chmod +x nofilter.sh
$ ls -l nofilter.sh
-rwxrwxrwx 1 deepak deepak    0 Aug  8 10:09 nofilter.sh
```

**6. Proving umask is not retroactive**
```bash
$ umask 022
$ touch old_file.txt
$ ls -l old_file.txt
-rw-r--r-- 1 deepak deepak 0 Aug  8 10:11 old_file.txt

$ umask 077
$ ls -l old_file.txt
-rw-r--r-- 1 deepak deepak 0 Aug  8 10:11 old_file.txt
# unchanged — umask only applies at creation time, use chmod for existing files
$ chmod 600 old_file.txt
$ ls -l old_file.txt
-rw------- 1 deepak deepak 0 Aug  8 10:11 old_file.txt
```

**7. Setting a restrictive umask before writing a secrets file in a deploy script**
```bash
$ cat deploy_secrets.sh
#!/usr/bin/env bash
set -euo pipefail
umask 077                     # ensure the secrets file is never group/world readable
cat > /opt/app/config/db_creds.env <<EOF
DB_PASSWORD=${DB_PASSWORD}
EOF
echo "Secrets written"

$ ./deploy_secrets.sh
Secrets written

$ ls -l /opt/app/config/db_creds.env
-rw------- 1 deploy deploy 42 Aug  8 10:15 /opt/app/config/db_creds.env
```

**8. systemd service umask independent of the shell's umask**
```bash
$ umask 077          # set in the interactive shell — irrelevant to systemd units

$ cat /etc/systemd/system/log-writer.service
[Unit]
Description=Log writer

[Service]
ExecStart=/opt/app/log-writer.sh
UMask=0027
User=appsvc

$ systemctl restart log-writer
$ ls -l /var/log/app/current.log
-rw-r----- 1 appsvc appsvc 128 Aug  8 10:18 /var/log/app/current.log
# 640 — matches UMask=0027 from the unit file, NOT the shell's umask 077
```

## Practice Questions

1. What does `umask` output when you type it with no arguments, and how is that different from what `umask -S` shows?
2. Given `umask 023`, what permissions will a newly created file get, and what will a newly created directory get? Show the bitwise AND-NOT working, not just the final number.
3. Why does a freshly created shell script never have the execute bit set, even if `umask` is `000`?
4. You run `umask 077` and then create `notes.txt`. A colleague says "just chmod the old files in this folder to match" — explain why that's necessary and what umask alone would NOT have done to those pre-existing files.
5. A CI pipeline writes an SSH private key to disk with default umask `022`, resulting in `-rw-r--r--`. Why is this a security problem, and what's the one-line fix before the file is written?
6. Your team's shared `/data` directory needs new files to be group-writable by default so any team member can edit them. What umask value would you set, and where would you put it so it applies to every team member's login shell?
7. A systemd-managed service writes log files that come out `644` even though the deploying engineer swears they set `umask 077` in their `.bashrc`. Explain why the shell's umask had no effect here, and how you'd actually fix the service's file permissions.
8. Explain the difference between `umask 022` and `umask -S u=rwx,g=rx,o=rx` — are they describing the same thing, and if so, why do they look inverted?
9. If `umask` is set to `133`, what will resulting file permissions be? Walk through the binary math (don't just guess by subtraction) and explain if subtraction would have given a different (wrong) answer here.
10. You inherit a legacy onboarding script that does `mkdir /srv/app && chmod -R 777 /srv/app` instead of relying on umask. What's wrong with that approach compared to setting an appropriate umask before creation, especially for files created later by the running application?

## Interview Key Points

- **umask is AND-NOT, not subtraction** — `final = base AND (NOT umask)`. Subtraction happens to give the right answer for common masks (022, 002, 077) but breaks conceptually and can mislead for less common masks; interviewers testing uncommon values (e.g. `023`, `133`) are specifically probing whether you understand the bitwise mechanic.
- **Files never get execute at creation** — base is 666 for files (no x), 777 for dirs; umask can only clear bits, never add them, so `umask 000` still yields a non-executable file.
- **umask has no retroactive effect** — it only applies at the moment of `creat()`/`mkdir()`; changing umask never changes permissions on files that already exist, `chmod` is the only fix for those.
- **`umask` vs `umask -S`** — raw octal shows the mask being cleared; `-S` shows the resulting *allowed* symbolic permissions, which is the inverse representation, and people conflate the two.
- **Persistence layers**: interactive-only (`umask` typed at prompt) vs shell rc files (`~/.bashrc`, `~/.profile`) vs system-wide (`/etc/profile`, `/etc/login.defs` UMASK, PAM `pam_umask`) — know which one wins and in what login path (interactive vs non-interactive, login vs non-login shell).
- **systemd units don't inherit the shell's umask** — services need their own `UMask=` directive in the unit file; this is a real production gotcha interviewers like to pose as "the shell umask is right but the daemon's files are still too open."
- **Security use case**: `umask 077` before writing credentials/keys in a deploy or provisioning script is a standard senior-level habit to mention — narrower than relying on a post-hoc `chmod`, since there's no window where the file briefly exists with looser permissions.
