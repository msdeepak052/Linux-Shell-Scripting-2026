# File Integrity & Auditing: `auditd`, `aide`

Two complementary tools answer two different questions after "was this system tampered with": AIDE tells you *what* changed since a known-good snapshot, `auditd` tells you *who did what, in real time, as it happened*.

## Explanation

**`auditd`** is the userspace daemon for the Linux kernel's **audit subsystem** — it doesn't decide what to log itself; it enforces **rules** you define (via `auditctl` or persisted in `/etc/audit/rules.d/audit.rules`) that tell the kernel which syscalls, files, or event types to record. Every matching event — a syscall, a file open/write/attribute-change, a user executing a specific binary — gets written to `/var/log/audit/audit.log` with rich context: PID, UID/EUID, the exact syscall, success/failure, and (crucially) a link back to the **originating user**, even through `sudo`, via `auid` (the "audit UID" / loginuid, which persists across `su`/`sudo` and doesn't change even if the process later runs as root — this is precisely what makes it forensically useful: you can prove *which human* triggered a root-level action).

Key rule types:
- **Watch rules** — `auditctl -w /etc/passwd -p wa -k passwd_changes`: watch a specific file/directory for writes (`w`) and attribute changes (`a`), tagged with a searchable key (`-k`).
- **Syscall rules** — `auditctl -a always,exit -F arch=b64 -S execve -k exec_commands`: log every invocation of a specific syscall (here, every command execution system-wide) — much higher volume, used for deep forensics or compliance mandates (PCI-DSS, STIG) rather than everyday monitoring.

Because rules only persist for the current boot unless written into `/etc/audit/rules.d/*.rules` (loaded by `augenrules` at boot), a very common mistake is testing with `auditctl -w ...` directly, being happy with the result, and then losing all rules on the next reboot.

**`aide`** (Advanced Intrusion Detection Environment) is a **file integrity monitoring (FIM)** tool: it builds a cryptographic-hash **database (baseline)** of a defined set of files/directories (typically system binaries, config files, libraries — things that shouldn't change outside of a controlled patch/deploy), then on each subsequent run **compares the current filesystem state against that baseline** and reports anything added, removed, or modified (by hash, permissions, ownership, size, or timestamp, depending on configured rules in `/etc/aide/aide.conf`). Unlike `auditd`, AIDE is **not real-time** — it's typically run on a schedule (cron/systemd timer), so it detects tampering *after the fact*, on the next scan, not the instant it happens.

**The auditd vs AIDE trade-off, concretely**: `auditd` sees everything as it happens but can be voluminous and, if an attacker gets root, its own logs/rules can potentially be tampered with unless shipped off-box (e.g., to a remote syslog/SIEM) immediately. AIDE's baseline database is a static file — if stored read-only or off-host (or on read-only media, or hash-verified against an external copy), it's much harder for an attacker to quietly "fix" what AIDE would report, but AIDE only catches changes at scan time, and if an attacker modifies a file and then triggers an AIDE re-baseline before anyone reviews the diff, the tampering becomes the new "normal."

### Which one should you actually use? (Decision rule)

| Need | Use | Why |
|---|---|---|
| Prove *who* did a specific privileged action, in real time, for compliance/forensics (PCI-DSS, STIG, SOC2 audits) | **auditd** | Kernel-level, tied to `auid`, survives `sudo`, near-real-time |
| Detect unauthorized changes to system binaries/configs that shouldn't change between patch windows | **aide** | Purpose-built hash-based baseline/diff, low overhead, simple periodic check |
| Comprehensive tamper detection strategy | **Both, together** | auditd for real-time who-did-what; AIDE as an independent periodic cross-check that doesn't rely on the same live logging pipeline an attacker with root might disable |

**Bottom line: they aren't substitutes — auditd answers "who/what happened right now," AIDE answers "has anything changed since the last known-good state," and a serious hardening posture runs both, with AIDE's database and auditd's logs both shipped off the monitored host so a compromised box can't erase its own evidence.**

## Hands-On Examples

**1. Checking auditd status and existing rules**
```bash
$ sudo systemctl status auditd --no-pager
● auditd.service - Security Auditing Service
     Active: active (running) since Fri 2026-08-08 08:02:11 UTC
$ sudo auditctl -l
No rules
```

**2. Adding a watch rule for a sensitive file (temporary, current boot only)**
```bash
$ sudo auditctl -w /etc/passwd -p wa -k passwd_changes
$ sudo auditctl -l
-w /etc/passwd -p wa -k passwd_changes
```

**3. Triggering and searching for the event**
```bash
$ sudo useradd testuser
$ sudo ausearch -k passwd_changes --start recent
type=SYSCALL msg=audit(1723134011.221:998): arch=c000003e syscall=257 success=yes exit=6
  a0=... comm="useradd" exe="/usr/sbin/useradd"
  subj=unconfined_u:system_r:useradd_t:s0 key="passwd_changes"
type=CWD msg=audit(1723134011.221:998): cwd="/root"
type=PATH msg=audit(1723134011.221:998): item=0 name="/etc/passwd"
  ouid=0 ogid=0
type=PROCTITLE msg=audit(1723134011.221:998): proctitle=75736572616464002D6D0074657374757365722D2D63726561746568...
```

**4. Making the rule persistent across reboots**
```bash
$ echo "-w /etc/passwd -p wa -k passwd_changes" | sudo tee /etc/audit/rules.d/passwd.rules
$ sudo augenrules --load
$ sudo systemctl restart auditd
$ sudo auditctl -l
-w /etc/passwd -p wa -k passwd_changes
```

**5. Auditing all command executions system-wide (higher-volume, compliance-driven rule)**
```bash
$ sudo auditctl -a always,exit -F arch=b64 -S execve -k exec_commands
$ sudo ausearch -k exec_commands -ts recent | grep comm
comm="bash" ... 
comm="systemctl" ...
comm="cat" ...
```
This kind of rule is common in PCI-DSS/STIG-compliant environments but generates significant log volume — usually paired with shipping logs off-box quickly.

**6. Installing AIDE and building the initial baseline**
```bash
$ sudo apt install aide
$ sudo aideinit
Start timestamp: 2026-08-08 09:10:02 +0000 (AIDE 0.18.6)
AIDE initialized database at /var/lib/aide/aide.db.new

$ sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

**7. Running an integrity check and interpreting a real diff**
```bash
$ sudo aide --check
AIDE found differences between database and filesystem!!

Summary:
  Total number of entries:       48213
  Added entries:                 1
  Removed entries:                0
  Changed entries:               1

---------------------------------------------------
Changed entries:
---------------------------------------------------
f  ...    ... : /etc/passwd

---------------------------------------------------
Detailed information about changes:
---------------------------------------------------
File: /etc/passwd
  SHA256 :         a1b2c3...        | e4f5a6...
  Mtime  : 2026-08-01 08:00:00      | 2026-08-08 09:12:44
  Size   : 2210                     | 2255

---------------------------------------------------
Added entries:
---------------------------------------------------
d      : /home/testuser
```
This matches the `useradd testuser` event `auditd` captured above — two independent tools corroborating the same change, which is exactly the kind of cross-check a security review looks for.

**8. Updating the baseline after a legitimate, reviewed change (e.g., after a controlled patch window)**
```bash
$ sudo aide --update
$ sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
$ sudo aide --check
AIDE found NO differences between database and filesystem. Looks okay!
```
The critical discipline here: **only re-baseline after confirming the change was legitimate** (cross-referenced against a change ticket, deploy log, or — as above — an auditd record). Blindly re-baselining on every AIDE alert defeats the entire purpose of the tool.

## Practice Questions

1. What's the fundamental difference in what `auditd` and `aide` actually detect — real-time event vs. point-in-time comparison? Give a scenario where only one of the two would catch a specific kind of tampering.
2. You add a rule with `auditctl -w /etc/shadow -p wa -k shadow_watch` and it works great — then the server reboots and the rule is gone. What happened, and how do you fix it permanently?
3. What is `auid` (loginuid) in an audit log entry, and why does it remain the same even after a user runs `sudo` to become root? Why does this matter for forensics?
4. AIDE reports a changed `/etc/passwd` and an added home directory. How would you determine whether this was a legitimate `useradd` or a sign of compromise, using both tools together?
5. What's the danger of "just re-running `aide --update` whenever it complains" as a standard operating procedure?
6. Why would you want to ship both auditd logs and the AIDE database off the monitored host itself? What specific attack scenario does this protect against?
7. Write an `auditctl` rule that logs every `execve` syscall system-wide, and explain why this specific rule type generates far more log volume than a simple file watch rule.
8. What's the operational trade-off of running `aide --check` very frequently (e.g., every 5 minutes) versus once a day?
9. A security audit (PCI-DSS/STIG) requires proof of who modified `/etc/sudoers` in the last quarter. Which tool answers this, and what would the actual audit trail look like?
10. Explain the difference between AIDE detecting a change via file hash versus via mtime/size alone — why is hash comparison considered the more reliable signal?

## Interview Key Points

- **auditd = real-time, kernel-level, "who did what right now"; AIDE = periodic, hash-based, "what's different from the known-good baseline"** — stating this distinction clearly and immediately is the single best way to show you actually understand both tools rather than treating them as interchangeable "security logging" trivia.
- **`auid`/loginuid is the forensic anchor** — it survives `su`/`sudo` privilege changes, letting you trace a root-level action back to the real human who triggered it; this is a frequently-tested detail because it's the actual reason auditd is valuable for compliance.
- **Rules added via `auditctl` are not persistent by default** — they must be written into `/etc/audit/rules.d/*.rules` and loaded via `augenrules` to survive a reboot; a classic "why did my audit rule disappear" real-world gotcha.
- **AIDE is not real-time — know this limitation cold.** It only catches what's changed as of the last scan; an attacker who modifies-then-reverts a file between two scheduled checks can potentially evade detection entirely.
- **Never blindly re-baseline AIDE on every alert** — that turns the tool into a rubber stamp; always cross-reference against a legitimate change record (ticket, deploy log, or an auditd entry) before updating the database.
- **Ship logs/baselines off-host** — both tools' evidentiary value depends on an attacker with root not being able to quietly erase or "fix" what they'd report; this is a standard senior-level answer to "how do you make audit logging tamper-resistant."
- **Watch rules (`-w`) vs syscall rules (`-a always,exit -S ...`)** in auditd represent a real volume/precision trade-off — know when you'd reach for each (specific sensitive file vs. broad forensic/compliance coverage).
- **File hash comparison (SHA-256 etc.) is stronger than relying on mtime/size alone** — an attacker can trivially forge a file's timestamp back to the original value, but can't forge its content to match the original hash; know why AIDE's hash-based detection is the meaningful signal.
