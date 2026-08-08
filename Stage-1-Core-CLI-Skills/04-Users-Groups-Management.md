# Users & Groups Management (`useradd`, `usermod`, `passwd`, `/etc/passwd`, `/etc/shadow`, `/etc/group`)

How Linux represents identity and access on disk, and the exact commands that create, modify, lock, and audit accounts — the daily-driver skill behind every onboarding/offboarding script a platform engineer writes.

## Explanation

### The three files that define identity

Every user and group fact on a Linux system ultimately resolves to three flat, colon-delimited text files. Commands like `useradd` and `usermod` are just safe, validated wrappers around editing these files.

**`/etc/passwd`** — one line per user, 7 fields:
```
username:x:UID:GID:GECOS:home_dir:shell
```
- Field 2 (`x`) is a placeholder. Historically the real password hash lived directly in this field — but `/etc/passwd` must be **world-readable** (every process needs to resolve UID→username, e.g. `ls -l`), so any user could copy the file and brute-force hashes offline. The fix (the "shadow suite") moved the actual hash to `/etc/shadow`, which is not world-readable, leaving `x` behind as a marker meaning "look in shadow."
- Field 3/4 are UID and primary GID (numeric). UID `0` is always root. UID `1`–`999` (RHEL/modern distros) or `1`–`499` (older/Debian convention) are reserved for system/service accounts (`nobody`, `sshd`, `www-data`, container runtimes, etc.) — no interactive login intended. UID `1000+` is the first regular human account on most modern distros (some older Debian systems started at 500 or 1000 differently — always check `/etc/login.defs` `UID_MIN` rather than assuming).
- Field 6/7 are home directory and login shell. A shell of `/usr/sbin/nologin` or `/bin/false` is the standard way to disable interactive login for a service account while still letting the account own files/processes.

**`/etc/shadow`** — one line per user, 9 fields, readable only by root (and the `shadow` group), typically mode `640` or stricter:
```
username:hashed_password:last_change:min:max:warn:inactive:expire:reserved
```
- `last_change` is days since the Unix epoch (1970-01-01) that the password was last set.
- `min`/`max`/`warn`/`inactive` are password-aging controls (see `chage` below).
- The hash field's prefix tells you the algorithm: `$6$` = SHA-512 (modern default), `$5$` = SHA-256, `$1$` = MD5 (legacy, weak), `$y$`/`$2b$` = yescrypt/bcrypt on newer distros. A value of `!` or `!!` means the account is **locked** (password login disabled but the account still exists), `*` means "no password login possible, ever" (typical for system accounts).

**`/etc/group`** — one line per group, 4 fields:
```
group_name:x:GID:member1,member2,member3
```
- The member list here is **supplementary members only**. A user's *primary* group (set via the GID field in `/etc/passwd`) does not need to appear in this list at all — this trips people up when grepping `/etc/group` for a user and not finding them, even though `id` shows them as a member of that group as their primary.

### The command layer

- **`useradd`** (low-level, present everywhere, RHEL/CentOS's traditional interactive default via `-D` config): by itself creates minimal entries and, on many distros, does **not** create a home directory unless you pass `-m`. It's scriptable and non-interactive by default — the right tool for automation.
- **`adduser`** (Debian/Ubuntu): a friendlier Perl wrapper around `useradd` that interactively prompts for password, full name, room number, etc., and creates the home directory by default. Great for humans at a terminal, less predictable for scripts (though it does support non-interactive flags). Know the distinction: on Debian-family systems `adduser` is the "nice" front end; `useradd` is still the underlying primitive.
- Key `useradd` flags: `-m` (create home dir, copying `/etc/skel`), `-s` (login shell), `-g` (primary group — must already exist), `-G group1,group2` (comma-separated supplementary groups at creation time), `-u` (force a specific UID), `-c` (GECOS/comment, usually full name), `-d` (custom home directory path instead of the default `/home/<user>`), `-r`/`--system` (create a system account: UID below `UID_MIN`, no password aging applied, no mail spool).

### The `-aG` vs `-G` trap

`usermod -G group1,group2 user` **replaces** the user's entire supplementary group list with exactly what you typed. Any group membership not listed is silently removed. `usermod -aG group1 user` **appends** — it adds `group1` while leaving every existing supplementary group intact. `-a` (append) is meaningless without `-G` and has no effect used alone.

This is one of the most common real-world production incidents in this domain: an engineer runs `usermod -G docker deploy` intending to *add* the `docker` group, and unknowingly strips `deploy` out of `sudo`/`wheel`/`sudoers`-relevant groups it already had, breaking automation that depended on that access — often not noticed until the next login or the next time that access is needed.

### `su` vs `sudo`

`su username` switches your shell to another user's identity. By default it requires **the target user's password** (or, if you're already root, no password at all since root can become anyone). `sudo command` runs a single command as another user (root by default) using **your own password**, and only if `/etc/sudoers` explicitly authorizes it. Consequences: `sudo` is auditable per-command (every invocation is logged with the actual command run), doesn't require sharing the root password among admins, and can be scoped tightly; `su` is coarser — once you're in, you have a full shell as that user with no further logging of individual commands unless something else (like `auditd`) is watching. `/etc/sudoers` must only ever be edited via `visudo`, which locks the file and syntax-checks it before saving, preventing a broken file from locking every admin out of `sudo` simultaneously.

### Which should you actually use? (Decision rule)

| Situation | Use | Why |
|---|---|---|
| Add a user to one more group without touching existing memberships | `usermod -aG group user` | `-G` alone silently replaces the full list — the #1 real-world footgun in this topic |
| Rebuild a user's supplementary groups from scratch (rare, deliberate) | `usermod -G newlist user` | Only correct when you explicitly intend to overwrite, and you've captured the current list first (`groups user`) in case you need to roll back |
| You need a full interactive shell/environment as another user for extended work | `su - username` (or `sudo -i` / `sudo su -`) | `-` gives a full login shell with that user's environment, not just identity |
| You need to run one privileged command, want it logged, and don't want to share root's password | `sudo command` | Per-command audit trail, uses your own credential, revocable independently per user via sudoers |
| Automating account creation in a script/config-management tool | `useradd` with explicit flags | Non-interactive and deterministic; never use `adduser` in scripts meant to be portable across distros |

## Hands-On Examples

**1. Creating a user the explicit (portable) way**
```bash
$ sudo useradd -m -s /bin/bash -c "Priya Sharma, Platform Team" -u 1042 priya
$ id priya
uid=1042(priya) gid=1042(priya) groups=1042(priya)
$ tail -1 /etc/passwd
priya:x:1042:1042:Priya Sharma, Platform Team:/home/priya:/bin/bash
```
Note `-m` was required — without it, `/home/priya` would not exist and first login would fail or land in `/`.

**2. The `-aG` vs `-G` bug, demonstrated**
```bash
$ groups priya
priya : priya sudo docker

# Intent: add priya to the "adm" group
$ sudo usermod -G adm priya
$ groups priya
priya : priya adm

# sudo and docker are GONE — usermod -G replaced the entire list
$ sudo usermod -aG sudo,docker,adm priya    # correct recovery
$ groups priya
priya : priya sudo docker adm
```

**3. Parsing `/etc/passwd` and `/etc/group` directly**
```bash
$ grep priya /etc/passwd
priya:x:1042:1042:Priya Sharma, Platform Team:/home/priya:/bin/bash

$ awk -F: '$3 >= 1000 && $3 < 60000 {print $1, $3}' /etc/passwd
priya 1042
jenkins 1043
deploy 1044

$ grep -E "^(sudo|docker):" /etc/group
sudo:x:27:priya,deepak
docker:x:999:priya,jenkins
```

**4. Locking and unlocking an account**
```bash
$ sudo passwd -l priya
passwd: password expiry information changed.
$ sudo grep priya /etc/shadow
priya:!$6$rZ9kLp2m$Hs8q...redacted...:19934:0:99999:7:::

# the "!" prepended to the hash is what "locked" means — login via password now fails
$ sudo passwd -S priya
priya L 08/08/2026 0 99999 7 -1

$ sudo passwd -u priya
$ sudo passwd -S priya
priya P 08/08/2026 0 99999 7 -1
```
`L` = locked, `P` = usable password set, `NP` = no password set.

**5. Password aging with `chage`**
```bash
$ sudo chage -l priya
Last password change                                   : Aug 08, 2026
Password expires                                       : never
Password inactive                                       : never
Account expires                                          : never
Minimum number of days between password change            : 0
Maximum number of days between password change            : 99999
Number of days of warning before password expires        : 7

$ sudo chage -M 90 -m 7 -W 14 priya
$ sudo chage -l priya | grep -E "Maximum|Minimum|warning"
Minimum number of days between password change            : 7
Maximum number of days between password change            : 90
Number of days of warning before password expires        : 14
```

**6. Deleting a user — with and without `-r`**
```bash
$ sudo userdel tempuser
$ ls -ld /home/tempuser
drwxr-xr-x 2 1050 1050 4096 Aug  1 09:00 /home/tempuser   # orphaned — owned by a now-nonexistent UID

$ sudo userdel -r otheruser
$ ls -ld /home/otheruser
ls: cannot access '/home/otheruser': No such file or directory   # home dir + mail spool removed too
```

**7. Group lifecycle: create, rename, delete**
```bash
$ sudo groupadd platform-oncall
$ getent group platform-oncall
platform-oncall:x:3005:

$ sudo usermod -aG platform-oncall priya
$ sudo groupmod -n sre-oncall platform-oncall
$ getent group sre-oncall
sre-oncall:x:3005:priya

$ sudo groupdel sre-oncall   # fails if it's still someone's PRIMARY group
groupdel: cannot remove the primary group of user 'someuser'
```

**8. Production-flavored onboarding script for a time-boxed contractor**
```bash
$ sudo useradd -m -s /bin/bash -c "J. Alvarez - Contractor - Acme Corp" \
    -G developers,vpn-users contractor_jalvarez
$ sudo passwd contractor_jalvarez
New password:
Retype new password:
passwd: password updated successfully

$ sudo chage -M 30 -W 7 -E "$(date -d '+30 days' +%Y-%m-%d)" contractor_jalvarez
$ sudo chage -l contractor_jalvarez | grep expires
Password expires                                       : Sep 07, 2026
Account expires                                          : Sep 07, 2026

$ id contractor_jalvarez
uid=1051(contractor_jalvarez) gid=1051(contractor_jalvarez) groups=1051(contractor_jalvarez),1002(developers),1010(vpn-users)
```
`-G` (not `-aG`) is correct *here* because this is account creation — there's no existing group list to preserve yet. The `-aG` rule only applies to `usermod` on an existing account.

## Practice Questions

1. You run `useradd -m contractor1` on a fresh RHEL box and the home directory is created, but on another team's Ubuntu box the same command leaves the user unable to log in properly. What's likely different, and what flag makes behavior explicit regardless of distro defaults?
2. A teammate ran `sudo usermod -G docker deploybot` to add Docker access to an existing automation account, and now the nightly deploy pipeline is failing with permission errors unrelated to Docker. Diagnose what happened and give the exact recovery command.
3. Given this `/etc/passwd` line — `svc_backup:x:302:302:Backup Service:/var/lib/backup:/usr/sbin/nologin` — explain every field and why the shell is set the way it is.
4. Why does `/etc/shadow` need to exist at all instead of just tightening the permissions on `/etc/passwd` to `600`?
5. You `grep` for a username in `/etc/group` and don't find it anywhere, yet `id username` clearly shows that user belongs to a group called `finance`. Explain why grep found nothing.
6. Write the command(s) to create a system account `svc_metrics` intended to run a monitoring daemon: no login shell, no home directory needed, UID below 1000.
7. A user's `/etc/shadow` entry shows `alice:!$6$...:19700:0:99999:7:::`. What does the `!` mean, and how do you fix it so `alice` can log in with a password again?
8. Design an offboarding sequence for a departing employee's account that preserves their home directory for a compliance hold but fully disables login. What commands, in what order?
9. Explain the exact difference between what `su db_admin` and `sudo -u db_admin bash` each require credential-wise, and why an auditor would prefer one over the other for a shared production database host.
10. You need to set a password to expire in exactly 45 days from today for a new hire, and want them warned starting 5 days before expiry. Which single command accomplishes this without touching `useradd`/`usermod`?

## Real Interview Questions (Company-Attributed)

- "Where is the user password stored on a modern Linux system?" — asked at *Alphadyne*

## Interview Key Points

- **`usermod -G` replaces, `usermod -aG` appends** — the single highest-yield gotcha in this whole topic; always state you'd verify with `groups user` before *and* after any `usermod -G` call in production.
- **`/etc/shadow` exists because `/etc/passwd` must stay world-readable** (UID/username resolution is needed by ordinary processes) — separating the hash out of a world-readable file is the entire rationale, and the `x` in `/etc/passwd`'s password field is the historical fingerprint of that migration.
- **UID ranges are a convention, not a kernel rule**: UID 0 = root, system/service accounts typically under `UID_MIN` (check `/etc/login.defs`, commonly 1000), regular humans at `UID_MIN` and above — interviewers probe whether you know this is configurable, not hardcoded.
- **`sudo` uses the caller's password and is logged per-command; `su` uses the target's password and hands over a full session** — know this cold, it's asked in nearly every sysadmin-adjacent interview in some form.
- **`/etc/group`'s member list is supplementary-only** — a user's primary group lives in `/etc/passwd` and won't appear in `/etc/group`'s member field, a frequent "why isn't this user listed" trap.
- **`userdel` without `-r` orphans the home directory** (and mail spool) — files remain, owned by a now-dangling UID, which is itself a minor security/hygiene issue (UID reuse later can grant a new, unrelated user access to old files).
- **Password-aging fields (`chage -M/-m/-W`, `passwd --expire`) and account locking (`passwd -l`, the `!` prefix) are distinct concepts** — locking blocks login now; aging controls force a *future* password change or expiry. Confusing the two is a common interview stumble.
- **`visudo`, never a raw editor, for `/etc/sudoers`** — syntax validation plus file locking prevents a typo from locking out every administrator at once.
