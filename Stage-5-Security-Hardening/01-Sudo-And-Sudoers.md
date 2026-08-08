# Sudo and /etc/sudoers (`visudo`, `sudoers.d`)

Sudo is how Linux does "controlled root" — the single most common access-control mechanism a platform engineer configures, and the easiest to misconfigure into a privilege-escalation hole.

## Explanation

**What `sudo` actually does**: it lets an authorized user run a command as another user (usually root), after re-authenticating with *their own* password (not root's). This is a fundamentally different model from `su`, which switches to the target user's shell and requires the *target's* password. Sudo's authorization decision, timeout, logging, and command restrictions are all governed by `/etc/sudoers` (and `/etc/sudoers.d/*`).

**Never edit `/etc/sudoers` directly** — always use `visudo`. `visudo` does two things a plain editor doesn't: it locks the file against concurrent edits, and — critically — it **syntax-checks the file before saving**, refusing to write a broken file that could lock every admin out of `sudo` (and out of fixing it, since fixing it also needs sudo/root). A typo in a raw-edited sudoers file is a classic "how do you recover" interview trap: boot into single-user/rescue mode, or use `pkexec`/root console access to fix it, since a broken sudoers file blocks `sudo` itself.

**Sudoers rule syntax**, in order:
```
user   host = (runas_user:runas_group)  command1, command2, ...
```
- `user` — username, `%groupname` for a Unix group, or an alias.
- `host` — almost always `ALL` (sudoers supports centralized multi-host configs, rarely used today).
- `(runas_user:runas_group)` — who the command runs as; omit to default to root.
- `command` — full path required (a bare command name is a security bug — see below), `ALL` for unrestricted.

Example: `deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart myapp` — user `deploy` can restart `myapp` as root, without a password prompt, and **nothing else**.

**`NOPASSWD`** skips the password re-prompt for that specific rule. Useful for automation (a CI runner triggering a restart) but expands blast radius if the command itself is a wildcard or accepts arguments — a very common interview "spot the danger" scenario.

**`%wheel` / `%sudo` groups**: on RHEL-family distros, membership in the `wheel` group typically grants full sudo via a pre-existing sudoers rule (`%wheel ALL=(ALL) ALL`); on Debian/Ubuntu, the equivalent group is usually `sudo`. Adding a user to that group is the fast/broad way to grant sudo; writing a scoped rule in `sudoers.d` is the narrow, auditable way — know both and when each is appropriate.

**`/etc/sudoers.d/`**: instead of editing the monolithic `/etc/sudoers`, drop a separate file per purpose/team into `/etc/sudoers.d/` (included via the `#includedir /etc/sudoers.d` directive at the bottom of `/etc/sudoers`). This is the standard modern practice: config-management tools (Ansible, Puppet, Chef) can safely template/own one file each without merge conflicts, and a bad file only breaks itself if validated with `visudo -cf` first. Files here must **not** have a dot or `~` in the name (`.bak`, `.rpmsave`, editor swap files) — `sudo` silently ignores files whose names contain a `.` unless they match `[A-Za-z0-9_-]+`, another classic gotcha ("I added a rule and it's not working" → filename had a `.conf` suffix or was left as `.rules.bak`).

**Command path restriction is a hard security requirement, not a style choice**: `deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl` (no arguments specified) lets `deploy` run `sudo systemctl <anything>`, including `systemctl restart sshd` or worse — restarting/masking security-relevant services. Always pin exact commands *and* arguments where possible, e.g. `/usr/bin/systemctl restart myapp` (no wildcard). A rule like `NOPASSWD: /usr/bin/vim *` is a well-known instant root-escalation bug — `vim` can shell out (`:!bash`), so granting sudo on an editor, pager, or interpreter without restricting further is equivalent to granting full root.

### Which one should you actually use? (Decision rule)

| Need | Use | Why |
|---|---|---|
| One-off broad admin access for a trusted human | Add user to `wheel`/`sudo` group | Fast, matches existing default rule, fine for a small number of trusted admins |
| Scoped access for a service account / CI bot / deploy user | A dedicated file in `/etc/sudoers.d/` with exact command paths + `NOPASSWD` only where automation truly needs it | Auditable, config-management friendly, minimizes blast radius, avoids editing the shared sudoers file |
| Emergency/rare full-root need for an otherwise-restricted user | Time-boxed manual `visudo` change, reverted after use (or short-lived rule + calendar reminder) | Avoids permanent privilege creep |

**Bottom line: prefer narrow, command-pinned rules in `/etc/sudoers.d/` over group-based blanket access whenever the requester is a service account or has a well-defined, limited job** — group membership is for trusted human admins who legitimately need broad access.

## Hands-On Examples

**1. Checking what a user can currently do**
```bash
$ sudo -l
Matching Defaults entries for deepak on webserver01:
    env_reset, mail_badpass, secure_path=/usr/local/sbin\:/usr/local/bin\:/usr/sbin\:/usr/bin\:/sbin\:/bin

User deepak may run the following commands on webserver01:
    (ALL : ALL) ALL
```

**2. Safely editing sudoers with `visudo`**
```bash
$ sudo visudo
# opens /etc/sudoers in $EDITOR with locking + syntax check on save

# If you introduce a typo and try to save:
>>> /etc/sudoers: syntax error near line 42 <<<
What now? Options are:
  (e)dit sudoers file again
  e(x)it without saving changes to sudoers file
```
Choosing `x` aborts the save entirely — the live `/etc/sudoers` is never left broken.

**3. Granting a scoped, auditable rule for a deploy user**
```bash
$ sudo visudo -f /etc/sudoers.d/deploy-restart
# add this single line:
deploy ALL=(root) NOPASSWD: /usr/bin/systemctl restart myapp, /usr/bin/systemctl status myapp
$ sudo chmod 440 /etc/sudoers.d/deploy-restart
$ sudo visudo -cf /etc/sudoers.d/deploy-restart
/etc/sudoers.d/deploy-restart: parsed OK
```
`440` permissions (root-owned, read-only, no write/execute for group/other) are required — sudoers ignores/`visudo`-warns on files with looser permissions.

**4. Testing the new rule as the deploy user**
```bash
deploy@webserver01:~$ sudo systemctl restart myapp
deploy@webserver01:~$ echo $?
0
deploy@webserver01:~$ sudo systemctl restart nginx
Sorry, user deploy is not allowed to execute '/usr/bin/systemctl restart nginx' as root on webserver01.
```

**5. A dangerous rule and why it's dangerous**
```bash
$ sudo cat /etc/sudoers.d/bad-rule
jenkins ALL=(ALL) NOPASSWD: /usr/bin/systemctl

# jenkins can now do literally anything systemctl can do, as root:
jenkins@ci01:~$ sudo systemctl stop firewalld
jenkins@ci01:~$ sudo systemctl edit sshd --full   # opens an editor as root — full root shell achievable
```
This is a canonical "find the vulnerability" interview scenario — the fix is pinning exact subcommands/units, never a bare binary.

**6. Group-based grant vs. `sudoers.d` rule**
```bash
$ sudo usermod -aG wheel newadmin      # RHEL/CentOS/Fedora: broad sudo via pre-existing %wheel rule
$ sudo usermod -aG sudo newadmin       # Debian/Ubuntu equivalent

$ getent group wheel
wheel:x:10:newadmin,deepak

# newadmin must log out/in (or start a new session) for the group membership to take effect
newadmin@host:~$ sudo whoami
root
```

**7. Auditing sudo usage after an incident**
```bash
$ sudo grep "sudo:" /var/log/auth.log | tail -5
Aug  8 14:22:01 webserver01 sudo:  deploy : TTY=pts/0 ; PWD=/home/deploy ; USER=root ; COMMAND=/usr/bin/systemctl restart myapp
Aug  8 14:30:44 webserver01 sudo:    jenkins : TTY=unknown ; PWD=/var/lib/jenkins ; USER=root ; COMMAND=/usr/bin/systemctl stop firewalld
```
Every sudo invocation is logged with the actual command, invoking user, and target user — this log is the first place to check during a security review or post-incident audit. On RHEL-family systems this is typically `/var/log/secure` instead of `/var/log/auth.log`.

**8. `sudoers.d` filename gotcha**
```bash
$ sudo visudo -f /etc/sudoers.d/deploy-rules.bak
# rule saved, but sudo silently IGNORES this file — filename contains a "."
$ sudo -l -U deploy
User deploy is not allowed to run sudo on webserver01.   # rule "exists" but is never applied

$ sudo mv /etc/sudoers.d/deploy-rules.bak /etc/sudoers.d/deploy-rules
$ sudo -l -U deploy
User deploy may run the following commands on webserver01:
    (root) NOPASSWD: /usr/bin/systemctl restart myapp
```

## Practice Questions

1. What's the actual difference between `sudo` and `su`, in terms of whose password is required and what gets logged?
2. Why must you always use `visudo` instead of directly editing `/etc/sudoers` with `vim` or `nano`? What specifically does `visudo` protect against?
3. A junior engineer writes `dev_user ALL=(ALL) NOPASSWD: /usr/bin/systemctl`. What's wrong with this rule, and how would you rewrite it to safely let `dev_user` restart only the `myapp` service?
4. Explain what `%wheel ALL=(ALL) ALL` means, line by line.
5. You add a new file to `/etc/sudoers.d/backup-rule.conf` and the rule doesn't seem to apply. What's the most likely cause, and how do you confirm it?
6. What permissions should files in `/etc/sudoers.d/` have, and why does `sudo` care?
7. A user reports `sudo: command not found` immediately after being added to the `sudo`/`wheel` group. What's the likely cause, and how do you fix it without rebooting the whole server?
8. Why is granting `NOPASSWD` sudo access to an editor like `vim`, `less`, or `nano` considered equivalent to giving full root access? What's the underlying mechanism?
9. How would you audit which commands a specific user has actually run via sudo over the last week?
10. Design a `sudoers.d` rule for a CI/CD service account that needs to restart exactly two services (`myapp`, `myapp-worker`) and read one log file, with no password prompt, following least-privilege.

## Interview Key Points

- **`sudo` re-authenticates the invoking user's own password; `su` requires the target user's password** — this single fact explains why `sudo` is preferred for shared admin access (no need to share the root password) and is almost always asked directly or implied.
- **Always `visudo`, never a raw editor** — know exactly what it protects against (syntax validation + file locking), not just "it's best practice."
- **Unrestricted or wildcard `NOPASSWD` rules on shell-capable binaries (editors, pagers, interpreters, `systemctl` with no unit specified) are privilege-escalation bugs, not just style issues** — this is the #1 practical "gotcha" interviewers probe for; be ready to name specific dangerous binaries (`vim`, `less`, `more`, `awk`, `python`, `find -exec`) known for GTFOBins-style sudo escapes.
- **`/etc/sudoers.d/` filenames must not contain a `.`** (or match invalid characters) — silently ignored otherwise; a real-world "why isn't my rule working" debugging scenario.
- **File permissions on sudoers files matter** — `440`, root-owned; sudo enforces strict permission checks on these files as a defense against tampering.
- **Command paths must be absolute in sudoers rules** — relative/bare command names are rejected or, worse, ambiguous depending on `$PATH`, which sudoers deliberately resets via `secure_path` to prevent `$PATH`-hijacking attacks.
- **Group-based access (`wheel`/`sudo`) vs. scoped `sudoers.d` rules is a real design decision** — know when broad trusted-admin access is appropriate versus when a service account needs a tightly pinned rule.
- **`sudo -l`** is the fast way to self-check (or audit another user's) effective sudo permissions — mention it as your go-to troubleshooting/audit command.
