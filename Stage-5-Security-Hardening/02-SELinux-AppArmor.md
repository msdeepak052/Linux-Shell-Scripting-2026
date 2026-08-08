# SELinux (RHEL) and AppArmor (Ubuntu) — Modes, Contexts, Troubleshooting Denials

Mandatory Access Control (MAC) that confines what a process can touch even if it's running as root — and the #1 cause of "it works when I `chmod 777` it but that's not the real fix" production mysteries.

## Explanation

Both SELinux and AppArmor are **Linux Security Modules (LSMs)** enforcing **Mandatory Access Control**: rules defined by the *system administrator/policy*, not by the resource owner (contrast with normal Unix permissions and ACLs, which are **Discretionary** — the file owner decides who gets access). Even root, running as UID 0, can be blocked by SELinux/AppArmor policy from doing something standard Unix permissions would otherwise allow. This is the core interview concept: **MAC adds a second, independent permission check on top of standard DAC (owner/group/other) permissions** — both must allow an action for it to succeed.

### SELinux (Security-Enhanced Linux) — RHEL/CentOS/Fedora/Amazon Linux

SELinux labels every process and every file with a **security context**: `user:role:type:level` (e.g., `system_u:object_r:httpd_sys_content_t:s0`). In practice, the **type** (`_t` suffix) is what almost all policy decisions key off — this model is called **Type Enforcement**. A process running with type `httpd_t` can only access files labeled with types that policy explicitly permits (like `httpd_sys_content_t`); it doesn't matter that the Unix file permissions say `644` and the process's UID technically "owns" the file — if the *type* doesn't match an allowed rule, SELinux denies it.

**Three modes** (`getenforce` / `/etc/selinux/config`):
- `Enforcing` — policy is applied; violations are blocked and logged.
- `Permissive` — policy violations are **only logged**, not blocked. Used for testing new policy/debugging without breaking production.
- `Disabled` — SELinux is off entirely (not recommended; loses all MAC protection, and re-enabling later requires a full filesystem relabel).

**Context lives on the file itself** (an extended attribute), separate from content — this is why **copying vs. moving** a file matters enormously: `cp` typically has the destination directory assign a *new* context based on policy defaults, while `mv` **preserves the original context**, which is a classic real-world bug (e.g., `mv` a web file in from `/tmp` — it keeps `tmp_t` and Apache can't serve it, even though `ls -l` shows normal `644` permissions and correct ownership).

### AppArmor — Ubuntu/Debian

AppArmor takes a simpler, **path-based** approach instead of a label-based type system: profiles (plain text files in `/etc/apparmor.d/`) list, per-application, exactly which file **paths** it may read/write/execute and which capabilities it may use — no relabeling of the filesystem required, which is why it's considered easier to adopt incrementally. Each profile has a mode:
- `enforce` — rules are applied and violations blocked.
- `complain` — violations are logged only, not blocked (AppArmor's equivalent of SELinux's Permissive, but scoped **per-profile** rather than system-wide).
- `unconfined` — no profile loaded for that binary at all; it runs under standard DAC only.

Because it's path-based, moving a confined app's data to an unexpected path can break it (no matching rule for the new path), and symlink tricks can sometimes be used to route around rules that weren't written carefully — a known relative weakness versus SELinux's label-based model, which follows the inode/xattr rather than the path.

### Which one should you actually use? (Decision rule)

**This is not a "pick your favorite" choice — it's determined by your distro family, and you will only ever configure the one that ships with what you're running.**

| Your distro | You get | Why |
|---|---|---|
| RHEL, CentOS, Fedora, Rocky, AlmaLinux, Amazon Linux | **SELinux** | Ships enabled by default (Enforcing) since RHEL 5+; red-hat ecosystem policy |
| Ubuntu, Debian, SUSE (also uses AppArmor) | **AppArmor** | Ships enabled by default on most profiles since Ubuntu 7.10+ |

**Bottom line: you don't choose between them on a given box — you learn whichever one matches the distro family you're operating on, and in a mixed RHEL+Ubuntu fleet (extremely common in real platform teams) you need working knowledge of both.** The one meaningful "choice" that exists is whether to run either of them at all versus disabling — and the correct default answer for production is always **leave it enabled and learn to troubleshoot denials properly**, not disable it to make an error go away. `setenforce 0` / disabling a profile is a debugging *step*, never a permanent fix.

### Troubleshooting denials

**SELinux**: denials are logged as **AVC (Access Vector Cache) denials**, typically in `/var/log/audit/audit.log` (readable via `ausearch`), and summarized human-readably by `sealert` (from `setroubleshoot`). The `audit2allow` tool can generate a custom policy module from observed denials — useful, but **don't blindly `audit2allow` everything into a new policy** without reviewing it; that's just quietly rebuilding "disabled" one rule at a time. Common fixes: `restorecon -Rv /path` (reset to the policy-defined default context), `semanage fcontext -a -t <type> '/path(/.*)?'` (persistently define a custom context mapping so it survives relabels), or `setsebool` for toggling policy-defined boolean switches (e.g., `httpd_can_network_connect`).

**AppArmor**: denials appear in `dmesg`/`journalctl`/`/var/log/kern.log` as `apparmor="DENIED"` lines showing the exact operation, path, and profile. `aa-status` shows loaded profiles and their mode; `aa-complain <profile>` / `aa-enforce <profile>` toggle a single profile's mode without touching others; `aa-logprof` interactively walks through recent denials and helps you add the missing rule to the profile.

## Hands-On Examples

**1. Checking current SELinux mode and status**
```bash
$ getenforce
Enforcing

$ sestatus
SELinux status:                 enabled
SELinuxfs mount:                /sys/fs/selinux
Current mode:                   enforcing
Mode from config file:          enforcing
Policy MLS status:              enabled
Policy from config file:        targeted
```

**2. Viewing and understanding a file's security context**
```bash
$ ls -Z /var/www/html/index.html
system_u:object_r:httpd_sys_content_t:s0 /var/www/html/index.html

$ ps -eZ | grep httpd
system_u:system_r:httpd_t:s0   1842 ?  00:00:00 httpd
```
Apache's process type (`httpd_t`) is allowed by policy to read files of type `httpd_sys_content_t` — that pairing is the whole access decision.

**3. Diagnosing a real AVC denial — Apache can't serve a moved file**
```bash
$ mv /home/deploy/newpage.html /var/www/html/newpage.html
$ curl -I http://localhost/newpage.html
HTTP/1.1 403 Forbidden

$ sudo ausearch -m avc -ts recent
type=AVC msg=audit(1723130421.552:9182): avc:  denied  { getattr } for  pid=1842 comm="httpd"
  path="/var/www/html/newpage.html" dev="dm-0" ino=8391293
  scontext=system_u:system_r:httpd_t:s0
  tcontext=unconfined_u:object_r:user_home_t:s0
  tclass=file permissive=0
```
The Unix permissions are fine (`644`, owned by `apache`) — SELinux blocked it because `mv` preserved the source's `user_home_t` type instead of picking up `httpd_sys_content_t`.

**4. Fixing it — relabel to the policy-correct default**
```bash
$ sudo restorecon -v /var/www/html/newpage.html
Relabeled /var/www/html/newpage.html from unconfined_u:object_r:user_home_t:s0 to system_u:object_r:httpd_sys_content_t:s0

$ curl -I http://localhost/newpage.html
HTTP/1.1 200 OK
```

**5. Making a non-standard content directory permanently correct**
```bash
$ sudo semanage fcontext -a -t httpd_sys_content_t "/srv/webapp(/.*)?"
$ sudo restorecon -Rv /srv/webapp
Relabeled /srv/webapp from unconfined_u:object_r:var_t:s0 to system_u:object_r:httpd_sys_content_t:s0
Relabeled /srv/webapp/index.html from unconfined_u:object_r:var_t:s0 to system_u:object_r:httpd_sys_content_t:s0
```
Without the persistent `fcontext` rule, a future `restorecon` (or a full relabel after reboot) would reset the context back to the wrong default — a common "the fix didn't survive a reboot" bug.

**6. Toggling an SELinux boolean instead of disabling enforcement**
```bash
$ getsebool httpd_can_network_connect
httpd_can_network_connect --> off
$ sudo setsebool -P httpd_can_network_connect on
$ getsebool httpd_can_network_connect
httpd_can_network_connect --> on
```
`-P` makes it persistent across reboots. This lets Apache proxy to a backend over the network — a real production need (reverse proxy setups) without disabling SELinux.

**7. AppArmor: checking status and a profile in complain mode**
```bash
$ sudo aa-status
apparmor module is loaded.
28 profiles are loaded.
25 profiles are in enforce mode.
   /usr/sbin/nginx
   /usr/sbin/mysqld
   /usr/bin/man
3 profiles are in complain mode.
   /usr/sbin/tcpdump
0 processes have profiles defined.
```

**8. AppArmor denial and the fix**
```bash
$ sudo journalctl -k | grep DENIED
Aug 08 15:02:11 web01 kernel: audit: type=1400 audit(1723132931.221:512): apparmor="DENIED"
  operation="open" profile="/usr/sbin/nginx" name="/srv/newapp/static/logo.png" pid=2211 comm="nginx" requested_mask="r" denied_mask="r" fsuid=33 ouid=33

# nginx's AppArmor profile doesn't allow reading from /srv/newapp/ (not the default /var/www path)
$ sudo aa-complain /usr/sbin/nginx        # temporarily stop enforcing while diagnosing
$ sudo vim /etc/apparmor.d/usr.sbin.nginx  # add: /srv/newapp/static/** r,
$ sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.nginx
$ sudo aa-enforce /usr/sbin/nginx          # back to enforcing with the new rule in place
```

## Practice Questions

1. What's the fundamental difference between DAC (standard Unix permissions) and MAC (SELinux/AppArmor)? Give an example where they'd produce different outcomes for the same file.
2. A file shows `-rw-r--r-- apache apache index.html` (looks completely fine) but Apache still gets a 403. What's the first thing you'd check, and with what command?
3. Explain the difference between `mv` and `cp` with respect to SELinux context, and why it causes a very specific, repeatable class of bug.
4. What's the difference between SELinux's `Permissive` mode and AppArmor's `complain` mode? Are they scoped the same way (system-wide vs per-application)?
5. Walk through diagnosing an SELinux AVC denial from scratch: which log, which tool to search it, and which two commands might fix it depending on whether the issue is a one-off mislabel or a persistent path mapping.
6. Why is `setenforce 0` (or disabling AppArmor/SELinux entirely) considered an anti-pattern for production troubleshooting, even though it "fixes" the symptom immediately?
7. If you're handed a fresh Ubuntu server and a fresh RHEL server and told to "make sure MAC is properly confining the web server," what would you actually check on each, given they use different tools?
8. What does `audit2allow` do, and why is blindly accepting everything it suggests considered risky practice?
9. Explain SELinux's Type Enforcement model in one or two sentences — what specifically determines whether an access is allowed?
10. AppArmor is path-based rather than label-based like SELinux — name one practical weakness this creates that SELinux's model doesn't have.

## Interview Key Points

- **SELinux and AppArmor are not competing options you choose between on the same system — they're tied to distro family** (SELinux: RHEL/Fedora/CentOS/Rocky/Alma/Amazon Linux; AppArmor: Ubuntu/Debian/SUSE). Which one you'll encounter depends on your distro, not your preference — stating this explicitly signals you understand the ecosystem rather than treating them as generic interchangeable "Linux security modules."
- **MAC vs DAC is the foundational concept**: even root can be denied by policy; standard Unix permissions being "correct" does NOT mean access will succeed — a very common trap in "why is this failing" scenarios.
- **`mv` preserves SELinux context, `cp` typically assigns a new one from the destination's defaults** — this exact gotcha (files moved from `/tmp` or home directories losing web-server access) is a favorite real-world troubleshooting question.
- **Never treat disabling SELinux/AppArmor as "the fix"** — it's a debugging step (temporarily, to confirm MAC is the cause) that should always be followed by a proper policy/context fix, not a permanent resolution. Interviewers specifically probe for candidates who reach for "just disable it" as a first instinct.
- **Know the exact commands cold**: `getenforce`/`setenforce`/`sestatus`, `ls -Z`/`ps -eZ`, `restorecon`, `semanage fcontext`, `setsebool -P`, `ausearch -m avc`, `audit2allow` for SELinux; `aa-status`, `aa-complain`/`aa-enforce`, `apparmor_parser -r`, `aa-logprof` for AppArmor.
- **`restorecon` (reset to policy default) vs `semanage fcontext -a` (define a new persistent mapping)** — know when you need one vs. both (a non-standard path needs `fcontext` first, or `restorecon` will just reset it back to the "wrong" default again).
- **SELinux booleans (`setsebool`)** are the correct way to enable a specific documented policy exception (e.g., allowing httpd to make network connections) instead of disabling enforcement — know this exists as the "proper" middle ground.
- **AppArmor's per-profile mode granularity** (each app can independently be enforce/complain/unconfined) versus SELinux's traditionally more system-wide Enforcing/Permissive toggle is a real architectural difference worth mentioning if asked to compare them directly.
