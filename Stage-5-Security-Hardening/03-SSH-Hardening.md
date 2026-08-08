# SSH Hardening: Disabling Root Login, Key-Only Auth, Fail2Ban

SSH is the single most attacked service on any internet-facing Linux box — hardening it is usually the first concrete task in any "secure this server" interview scenario.

## Explanation

Default `sshd` configuration is intentionally permissive (password auth on, root login often allowed) to make first-boot access easy. Every hardening step below trades a bit of convenience for closing a specific, well-understood attack path. The config file is `/etc/ssh/sshd_config` (server-side — don't confuse with `/etc/ssh/ssh_config`, the client-side defaults).

**Disabling root login** (`PermitRootLogin no`): stops anyone from SSH'ing in directly as `root`, forcing them through a named, individually-auditable account plus `sudo`. This closes the single highest-value brute-force/credential-stuffing target (every Linux box has a `root` account by definition, so attackers don't even need to guess a username) and guarantees every privileged action is attributable to a real person via sudo logs, not an anonymous shared root login. `PermitRootLogin` also accepts `prohibit-password` (root can log in **only** with a key, no password) — a useful middle ground for break-glass/automation scenarios that still need direct root key access without password brute-force risk.

**Key-only authentication** (`PasswordAuthentication no`): eliminates password brute-forcing entirely — the overwhelming majority of internet SSH attack traffic is automated password guessing against common usernames. SSH keys (asymmetric: a private key stays on the client, a public key is installed server-side in `~/.ssh/authorized_keys`) are effectively immune to brute force (a modern key is computationally infeasible to guess) and support passphrase-protecting the private key plus `ssh-agent` for convenience. **Ed25519** is the modern recommended key type — smaller, faster, and at least as secure as RSA-4096, which is now mostly kept around only for legacy compatibility with old systems. Generate with `ssh-keygen -t ed25519`.

**`AllowUsers` / `AllowGroups`**: an explicit allow-list restricting *which* accounts may SSH in at all, regardless of whether they technically have valid credentials — defense in depth in case an unintended account (a shared service account, a leftover test user) somehow has a working key or password.

**Changing/limiting the listening surface**: `Port` (moving off 22 mostly just reduces automated scanner noise/log volume — it is **not** real security, and interviewers specifically probe whether you understand this distinction: "security through obscurity" reduces noise but doesn't stop a targeted attacker who port-scans), `MaxAuthTries` (caps failed attempts per connection before it's dropped), `LoginGraceTime` (how long an unauthenticated connection can stay open — lowering this mitigates slow-connection resource-exhaustion attacks).

**`fail2ban`**: a separate daemon, not part of `sshd` itself, that watches auth logs (`/var/log/auth.log` on Debian/Ubuntu, `/var/log/secure` on RHEL) for repeated failed-login patterns and dynamically inserts firewall rules (via `iptables`/`nftables`/`firewalld`) to temporarily ban the offending IP. It's a **compensating control for noise and resource exhaustion**, not a replacement for key-only auth — with `PasswordAuthentication no` already in place, brute force is already impossible, but fail2ban still meaningfully reduces log spam, connection churn, and CPU spent on the SSH handshake/auth negotiation for every rejected attempt, and it also catches other auth-log-based attacks (e.g., repeated invalid usernames).

### Which controls actually matter most? (Decision rule)

| Control | Stops | Priority |
|---|---|---|
| `PasswordAuthentication no` + key-only auth | Brute force / credential stuffing (the #1 real attack) | **Do this first, always** |
| `PermitRootLogin no` | Anonymous root target, non-attributable privileged access | **Do this first, always** |
| `fail2ban` | Log/resource noise from repeated attempts (defense in depth once keys are enforced) | High, but secondary to the above |
| `AllowUsers`/`AllowGroups` | Unintended accounts having usable credentials | Medium — good practice, narrow blast radius |
| `MaxAuthTries`, `LoginGraceTime` tuning | Resource exhaustion, slow-attack mitigation | Medium |
| Changing the port off 22 | **Nothing security-relevant** — only reduces scanner log noise | Low / cosmetic, don't present this as a real defense in an interview |

**Bottom line: key-only auth + no root login close roughly the entire practical SSH attack surface; everything else (fail2ban, allow-lists, port changes, rate limits) is defense-in-depth layered on top, not a substitute for those two.**

## Hands-On Examples

**1. Generating a modern SSH key pair**
```bash
$ ssh-keygen -t ed25519 -C "deepak@laptop-2026"
Generating public/private ed25519 key pair.
Enter file in which to save the key (/home/deepak/.ssh/id_ed25519):
Enter passphrase (empty for no passphrase):
Your identification has been saved in /home/deepak/.ssh/id_ed25519
Your public key has been saved in /home/deepak/.ssh/id_ed25519.pub
```

**2. Installing the public key on the server**
```bash
$ ssh-copy-id -i ~/.ssh/id_ed25519.pub deploy@webserver01
$ ssh deploy@webserver01
Last login: Fri Aug  7 09:14:02 2026 from 10.0.1.20
deploy@webserver01:~$
```

**3. Confirming password auth still works before you cut it off (important safety step!)**
```bash
$ ssh -o PubkeyAuthentication=no deploy@webserver01
deploy@webserver01's password:
```
Never disable `PasswordAuthentication` until you've confirmed key-based login works — locking yourself out of a remote box with no console access is a real, common, career-defining mistake.

**4. Hardening `sshd_config` — the core changes**
```bash
$ sudo vim /etc/ssh/sshd_config
```
```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers deploy deepak
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
```

**5. Validating config syntax before restarting (critical — don't skip this)**
```bash
$ sudo sshd -t
$ echo $?
0
```
`sshd -t` catches syntax errors before you restart the daemon — restarting with a broken config can drop the SSH service entirely, and on a remote-only box that's an outage requiring out-of-band (console/IPMI) access to fix.

**6. Applying the change safely (keep an existing session open!)**
```bash
$ sudo systemctl restart sshd
```
```bash
# In a SEPARATE terminal/session, BEFORE closing your first one, verify a fresh login works:
$ ssh deploy@webserver01
Last login: Fri Aug  8 15:40:11 2026 from 10.0.1.20
deploy@webserver01:~$

$ ssh -o PasswordAuthentication=yes -o PubkeyAuthentication=no root@webserver01
root@webserver01: Permission denied (publickey).
```
Root login and password auth are both now rejected — but your key-based session as `deploy` still works, confirming the change didn't lock you out.

**7. Installing and configuring fail2ban for SSH**
```bash
$ sudo apt install fail2ban
$ sudo tee /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 4
bantime = 3600
findtime = 600
EOF
$ sudo systemctl restart fail2ban
$ sudo fail2ban-client status sshd
Status for the jail: sshd
|- Filter
|  |- Currently failed: 2
|  |- Total failed:     47
|  `- Journal matches:  _SYSTEMD_UNIT=sshd.service + _COMM=sshd
`- Actions
   |- Currently banned: 1
   |- Total banned:     6
   `- Banned IP list:   203.0.113.44
```

**8. Investigating an active ban and manually unbanning a false positive**
```bash
$ sudo fail2ban-client status sshd
...
   `- Banned IP list:   203.0.113.44 198.51.100.9

$ sudo grep "203.0.113.44" /var/log/auth.log | tail -3
Aug  8 15:02:11 webserver01 sshd[9021]: Failed password for invalid user admin from 203.0.113.44 port 51122 ssh2
Aug  8 15:02:14 webserver01 sshd[9021]: Failed password for invalid user admin from 203.0.113.44 port 51130 ssh2

$ sudo fail2ban-client set sshd unbanip 198.51.100.9
198.51.100.9
```

## Practice Questions

1. Why does disabling password authentication (`PasswordAuthentication no`) matter more for security than moving SSH off port 22? What does changing the port actually accomplish, and what does it not accomplish?
2. Walk through the exact safe sequence for hardening `sshd_config` on a remote-only production box (no console access) — what would you verify, and in what order, to avoid locking yourself out?
3. What's the practical difference between `PermitRootLogin no` and `PermitRootLogin prohibit-password`? Give a scenario where you'd want the latter instead of a flat `no`.
4. A teammate says "we don't need fail2ban since we already disabled password auth." Do you agree? What does fail2ban still protect against once brute force is already impossible?
5. Explain what `ssh-copy-id` actually does under the hood — what file does it modify on the server, and what would you do manually if `ssh-copy-id` weren't available?
6. Why is Ed25519 generally recommended over RSA for new SSH keys in 2026? Is there a scenario where you'd still choose RSA?
7. You run `sudo systemctl restart sshd` after an `sshd_config` edit and immediately lose all SSH access to the box. What two things should you have done beforehand to prevent or quickly recover from this?
8. What does `MaxAuthTries` control, and how is it different from what fail2ban does?
9. Design an `AllowUsers`/`AllowGroups` policy for a server where only members of the `ops` group and one named service account (`ci-deploy`) should ever be able to SSH in.
10. A fail2ban jail bans an IP after 4 failed attempts within 10 minutes for 1 hour. A legitimate admin gets banned after fat-fingering their passphrase 4 times. What command unbans them immediately, and what would you tune to reduce false positives going forward?

## Real Interview Questions (Company-Attributed)

- "How will you disable root login on a particular server?" — asked at *IBM*

## Interview Key Points

- **Key-only auth (`PasswordAuthentication no`) + `PermitRootLogin no` are the two highest-impact changes** — closing brute force and anonymous root access respectively. Lead with these if asked "how do you harden SSH," don't bury them in a long list.
- **Changing the SSH port is noise reduction, not security** — a well-known "sounds like security but isn't" trap; be ready to say this explicitly rather than presenting it as a real hardening step.
- **`sshd -t` before every restart, and never close your current session until a fresh connection is verified** — the single most common real-world SSH-hardening mistake is a remote lockout from a bad config; interviewers often probe for this operational discipline specifically.
- **fail2ban is a compensating/defense-in-depth control, not a substitute for key-only auth** — know it reduces log noise and resource exhaustion and catches other auth-log patterns, but doesn't do the primary job once passwords are already disabled.
- **`PermitRootLogin prohibit-password`** is a nuanced middle-ground option worth knowing — allows root key-based access (useful for certain automation/break-glass cases) while still blocking root password brute force.
- **Ed25519 over RSA for new keys** — smaller, faster, modern default; know RSA-4096 is still acceptable for legacy compatibility.
- **`AllowUsers`/`AllowGroups` is defense in depth**, not the primary control — it narrows who can even attempt auth, catching accidentally-valid credentials on unintended accounts.
- **Auth log location differs by distro** (`/var/log/auth.log` Debian/Ubuntu vs `/var/log/secure` RHEL/CentOS) — a small but real detail that trips people up when configuring fail2ban's `logpath` on the "other" family.
