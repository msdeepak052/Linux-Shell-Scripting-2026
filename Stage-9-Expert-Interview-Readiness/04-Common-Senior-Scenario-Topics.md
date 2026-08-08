# Common Senior Scenario Topics (Capstone Troubleshooting Walkthroughs)

The whiteboard questions every senior/SRE interview reaches for — five realistic incidents, walked symptom → diagnosis → root cause → fix.

## Explanation

These scenarios show up constantly in senior/SRE interviews because they test the same underlying skill: **systematic diagnosis under ambiguity**, not memorized commands. The pattern that separates senior candidates from junior ones:

1. **Don't guess — observe first.** Reproduce/confirm the symptom precisely before touching anything.
2. **Narrow the search space methodically.** Work top-down (system → service → process → resource) or bottom-up depending on the symptom.
3. **Form a hypothesis, then a cheap test for it** — don't jump straight to the fix.
4. **Fix the root cause, not just the symptom** — and say out loud what you'd do to prevent recurrence (monitoring, alerting, guardrail).
5. **Narrate as you go.** In an interview, silently typing commands loses points versus explaining *why* each command is the next logical step.

The five canonical scenarios below each hide a specific "aha" — disk full but `df -h` looks fine (inodes or deleted-but-open files), a service failing for a non-obvious reason, load high but CPU-bound vs IO-bound vs run-queue-bound, DNS resolution breaking at one specific layer, and "works on one node but not another" being a config/environment drift problem. Recognizing *which class* of problem you're in from the symptom is the actual skill being tested.

## Hands-On Examples

### Scenario 1: "Disk is full, but `df -h` shows plenty of space"

**Symptom:** Application logs errors like `No space left on device` on writes, but the on-call engineer swears there's room.

```bash
$ df -h
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2   50G   18G   30G  38% /
```
Confusing — 38% used, plenty free. Two classic causes to check next: **inode exhaustion** and **deleted-but-still-open files**.

```bash
$ df -i
Filesystem       Inodes  IUsed   IFree IUse% Mounted on
/dev/nvme0n1p2  3276800 3276800      0  100% /
```
There it is — **inode usage is 100%** even though block usage is only 38%. Something is creating a huge number of tiny files. Find the culprit directory:
```bash
$ find / -xdev -printf '%h\n' 2>/dev/null | sort | uniq -c | sort -rn | head -5
   1842213 /var/spool/app/tmp_sessions
     91022 /var/log/app/debug
     12003 /tmp
       884 /home/deploy
       201 /etc
```
Root cause: an app writing one small session file per request into `/var/spool/app/tmp_sessions` and never cleaning up (a broken cron cleanup job, confirmed separately with `systemctl status app-session-cleanup.timer` showing `inactive (dead)`).

**Fix:**
```bash
$ find /var/spool/app/tmp_sessions -type f -mtime +1 -delete
$ df -i | grep nvme0n1p2
/dev/nvme0n1p2  3276800  812340 2464460  25% /
$ systemctl enable --now app-session-cleanup.timer   # restore the broken cleanup job
```
**If block usage itself had been the issue** (df -h showing 100% but `du` not finding big files), the other classic cause is a deleted file still held open by a process:
```bash
$ df -h /var/log
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2   50G   49G   0.2G  99% /var/log
$ du -sh /var/log/* | sort -rh | head -5
1.2G  /var/log/app
800M  /var/log/nginx
...                                      # doesn't add up to 49G used
$ lsof +L1 2>/dev/null | grep deleted
app        2341  appuser   4w   REG  259,2  47G     0  /var/log/app/debug.log (deleted)
```
A log file was rotated (unlinked) while a process still held its file descriptor open — space isn't reclaimed until that FD closes. Fix: `systemctl restart app` (releases the FD) or, better, `> /proc/2341/fd/4` to truncate it live without restarting, then fix log rotation to `copytruncate` or signal the app (`postrotate`/`HUP`) instead of unlink-and-recreate.

### Scenario 2: "Service won't start"

**Symptom:** `systemctl start myapp` fails immediately.

```bash
$ systemctl start myapp
Job for myapp.service failed because the control process exited with error code.
See "systemctl status myapp.service" and "journalctl -xeu myapp.service" for details.

$ systemctl status myapp.service
● myapp.service - My Application
     Loaded: loaded (/etc/systemd/system/myapp.service; enabled)
     Active: failed (Result: exit-code) since Sat 2026-08-08 09:12:03 UTC; 5s ago
    Process: 18422 ExecStart=/opt/myapp/bin/myapp --config /etc/myapp/config.yml (code=exited, status=1/FAILURE)
   Main PID: 18422 (code=exited, status=1/FAILURE)
```
Exit status 1, generic. Pull the actual application error from the journal:
```bash
$ journalctl -xeu myapp.service --no-pager | tail -20
Aug 08 09:12:03 host myapp[18422]: FATAL: failed to bind to port 8080: address already in use
Aug 08 09:12:03 host myapp[18422]: config load OK, starting listener...
```
Root cause found: port conflict. Confirm what's holding it:
```bash
$ ss -ltnp | grep :8080
LISTEN  0  128  0.0.0.0:8080  0.0.0.0:*  users:(("myapp",pid=15901,fd=6))
```
A **previous instance (PID 15901)** of the same app is still running — the last deploy's stop step silently failed (maybe `systemctl stop` timed out and systemd gave up, or it was launched manually outside systemd and orphaned).

**Fix:**
```bash
$ kill 15901
$ sleep 2
$ ss -ltnp | grep :8080          # confirm port is free
$ systemctl start myapp
$ systemctl is-active myapp
active
```
Longer-term fix: check `TimeoutStopSec` in the unit file and add `ExecStartPre=/bin/sh -c '! ss -ltn | grep -q :8080'` or a proper pre-start port check, and investigate why the old process wasn't reaped during the last deploy (bad `stop`/`restart` orchestration in the deploy script).

**Other common "service won't start" root causes worth naming in an interview:** missing/misconfigured config file (`ExecStartPre` validation catches this), permission errors on a data directory (`Permission denied` in journal, fixed with `chown`/`ExecStartPre=+chown`), a bad env file referenced by `EnvironmentFile=` that doesn't exist, or a `SELinux`/`AppArmor` denial (`ausearch -m avc -ts recent`).

### Scenario 3: "Sudden high load"

**Symptom:** Alert fires: load average on a web server jumped from ~2 to ~40.

```bash
$ uptime
 09:45:02 up 30 days,  4:12,  2 users,  load average: 41.32, 38.90, 22.15
```
Load average alone doesn't say *why* — it counts both CPU-runnable AND uninterruptible-sleep (usually I/O-wait) processes. Split CPU vs I/O first:
```bash
$ vmstat 1 5
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
38  4  102400 512300  88120 2103400    0    0   120  8800 4200 9100 12  6 15 67  0
```
`wa` (I/O wait) is 67% — this is **I/O-bound, not CPU-bound**. `b` column (processes blocked on I/O) is nonzero too. Find what's hammering disk:
```bash
$ iostat -xz 1 5
Device            r/s     w/s   rkB/s   wkB/s  await  %util
nvme0n1          12.00  890.00   480.0 112000.0  340.5  99.8
```
Disk is at 99.8% utilization with a huge write rate and 340ms average wait — the disk itself is the bottleneck. Find which process:
```bash
$ iotop -oPa -n 3
  PID  USER   DISK READ  DISK WRITE  SWAPIN  IO>    COMMAND
 22190 app        0.00 B    9.80 G    0.00%  94.20%  java -jar batch-export.jar
```
Root cause: a scheduled batch export job (cron-triggered nightly report, meant to run at 02:00 but a recent change moved it to run on-demand, and it got triggered during peak traffic) is writing ~10GB to disk and starving the web app's I/O.

**Fix (immediate):**
```bash
$ kill -STOP 22190        # pause it without losing work, confirm load drops
$ vmstat 1 3               # wa drops back to normal, r/b queues shrink
$ kill -CONT 22190         # resume it once traffic-serving is confirmed healthy, or reschedule
```
**Root fix:** move the batch job back to low-traffic hours via its scheduler, add `ionice -c2 -n7` (best-effort, low priority) to the job so it never starves interactive I/O again, and add disk-`%util`/`await` alerting so this is caught before load average spikes.

**Contrast — if `vmstat` had shown high `us`/`sy` and near-zero `wa`**, this is CPU-bound instead, and the next command is `top`/`pidstat -p ALL 1` to find the runaway process, then `perf top -p <pid>` or a language-specific profiler to see what it's actually doing (infinite loop, GC thrashing, thundering-herd retries, etc.) — a different investigation branch entirely, which is why splitting CPU-bound vs I/O-bound via `vmstat` first is the critical early step.

### Scenario 4: "DNS resolution failure"

**Symptom:** App logs `could not resolve host: api.internal.example.com`, intermittently.

```bash
$ nslookup api.internal.example.com
;; connection timed out; no servers could be reached
```
Total failure to reach any resolver — start at the bottom of the resolution chain and work up:
```bash
$ cat /etc/resolv.conf
nameserver 10.0.0.2
nameserver 10.0.0.3
options timeout:1 attempts:1
```
`timeout:1 attempts:1` is aggressive — one dropped UDP packet and resolution fails outright. Test the nameservers directly:
```bash
$ dig @10.0.0.2 api.internal.example.com +time=3
;; connection timed out; no servers could be reached

$ dig @10.0.0.3 api.internal.example.com +time=3
;; ANSWER SECTION:
api.internal.example.com. 300 IN A 10.0.5.44
```
10.0.0.2 (primary resolver) is unreachable/down; 10.0.0.3 (secondary) works fine. Confirm reachability at the network layer:
```bash
$ ping -c3 10.0.0.2
PING 10.0.0.2: 3 packets transmitted, 0 received, 100% packet loss

$ ping -c3 10.0.0.3
PING 10.0.0.3: 3 packets transmitted, 3 received, 0% packet loss
```
Root cause: primary internal DNS server (10.0.0.2) is down/unreachable (confirmed separately by the networking team — it was an AZ-local resolver that had a node failure). Because `attempts:1` means glibc's resolver gives up after the FIRST nameserver fails to answer within 1s, rather than falling through to the working secondary quickly/reliably, requests intermittently fail depending on which nameserver is tried first and how the retry/rotate logic behaves.

**Fix (immediate):**
```bash
# Remove the dead resolver so only the healthy one is used
$ sudo sed -i '/10.0.0.2/d' /etc/resolv.conf
$ dig api.internal.example.com +time=3
;; ANSWER SECTION:
api.internal.example.com. 300 IN A 10.0.5.44
```
**Root fix:** page the team owning 10.0.0.2 to restore it (this is a shared resolver, other hosts are affected too), raise `options timeout:2 attempts:2` for resilience against single dropped packets, and if on cloud infra, verify `/etc/resolv.conf` is being correctly regenerated by DHCP/cloud-init and not stuck with a stale value after an AZ failover.

**Other DNS-failure branches worth knowing:** `/etc/nsswitch.conf` misconfigured (`hosts:` line missing `dns`), a broken local caching resolver (`systemd-resolved` stuck — `resolvectl status` / `systemctl restart systemd-resolved`), `/etc/hosts` stale override shadowing real DNS, or search-domain issues (`search internal.example.com` appended incorrectly causing FQDN mismatches) — diagnosed via `dig +search` vs a fully-qualified `dig api.internal.example.com.` (trailing dot bypasses search domains).

### Scenario 5: "It works on one node but not another"

**Symptom:** Deploy to a 5-node fleet; app crashes on `node-04` only, others healthy.

```bash
$ ssh node-04 systemctl status myapp
● myapp.service - Active: failed (Result: exit-code)
$ ssh node-04 journalctl -xeu myapp --no-pager | tail -5
Aug 08 10:02:11 node-04 myapp[9021]: FATAL: undefined symbol: EVP_KDF_CTX_new (from libcrypto.so.1.1)
```
A shared-library symbol mismatch — classic "different environment" bug. Compare the same binary/library across nodes:
```bash
$ for h in node-0{1,2,3,4,5}; do
    echo "== $h =="
    ssh "$h" 'openssl version; dpkg -l | grep libssl'
  done
== node-01 ==
OpenSSL 1.1.1f
ii  libssl1.1  1.1.1f-1ubuntu2.19
== node-04 ==
OpenSSL 3.0.2
ii  libssl3    3.0.2-0ubuntu1.15
== node-05 ==
OpenSSL 1.1.1f
ii  libssl1.1  1.1.1f-1ubuntu2.19
```
Root cause found: `node-04` was rebuilt more recently from a newer base image (or had an unmanaged `apt upgrade` run on it) and has OpenSSL 3.0 instead of 1.1.1 — the app binary was linked against `libssl1.1` and the symbol doesn't exist in the newer major version. This is **configuration/environment drift**, not an app bug.

**Diagnosis checklist for "works on one node, not another" in general** (walk this whenever seen):
```bash
# 1. Package/library version drift
$ diff <(ssh node-01 dpkg -l) <(ssh node-04 dpkg -l)

# 2. Config file drift
$ diff <(ssh node-01 cat /etc/myapp/config.yml) <(ssh node-04 cat /etc/myapp/config.yml)

# 3. Environment variable / systemd unit drift
$ diff <(ssh node-01 systemctl cat myapp) <(ssh node-04 systemctl cat myapp)

# 4. Kernel/OS version drift
$ for h in node-0{1,4}; do ssh "$h" uname -r; done
node-01: 5.15.0-91-generic
node-04: 6.2.0-33-generic     # different kernel — also worth checking for behavioral differences

# 5. Filesystem/permissions drift
$ diff <(ssh node-01 stat /opt/myapp/data) <(ssh node-04 stat /opt/myapp/data)

# 6. Was this node provisioned by the SAME automation as the others?
$ ssh node-04 cat /etc/ansible-facts/last_run 2>/dev/null || echo "not managed by same playbook run!"
```
On `node-04`, step 6 revealed it: it had been manually patched by another engineer outside the normal Ansible run (an out-of-band `apt upgrade` "just to fix a CVE" that pulled in the new OpenSSL major version), so it drifted from the fleet's pinned baseline.

**Fix:**
```bash
$ ssh node-04 'sudo apt install --allow-downgrades libssl1.1=1.1.1f-1ubuntu2.19'
# or, correctly: rebuild node-04 from the standard image / re-run the full
# Ansible/Packer baseline so it matches the fleet exactly, rather than
# hand-patching further drift on top of drift
$ ansible-playbook -i inventory site.yml --limit node-04
$ ssh node-04 systemctl start myapp && systemctl is-active myapp
active
```
**Root fix / prevention:** lock down who/what can run ad-hoc package changes on fleet nodes outside of IaC (immutable infrastructure / golden AMIs prevent this class of bug entirely), and add a drift-detection job (`ansible-playbook --check` on a schedule, or a config-compliance tool) that alerts when a node's installed packages diverge from the fleet baseline.

## Practice Questions

1. `df -h` shows a filesystem is only 40% full, but the application is getting `No space left on device`. Walk through your diagnosis, including the two most common non-obvious causes.
2. A `systemctl start` fails with a generic exit-code error. What's the very next command you run, and why does `systemctl status` alone often not tell you enough?
3. Load average spikes from 2 to 40 on a web server. What's the first command you run to determine whether this is CPU-bound or I/O-bound, and why does that distinction matter for your next steps?
4. DNS resolution is intermittently failing for one internal hostname. List the resolution chain layers you'd check in order, from `/etc/resolv.conf` down to the actual nameserver.
5. An app crashes on exactly one node out of five in a fleet, right after a deploy. What's your systematic checklist for finding what's different about that node?
6. A log file was deleted (rotated) but disk usage hasn't gone down. Explain why, and how you'd find and reclaim the space without necessarily restarting the service.
7. You find a process in uninterruptible sleep (`D` state) during a high-load investigation. What does that state specifically indicate, and what would you check next?
8. Explain the difference between `attempts` and `timeout` options in `/etc/resolv.conf`, and how a misconfigured value can cause intermittent (not total) DNS failures.
9. During a "works on node A, not node B" investigation, `dpkg -l` diffs come back identical on both nodes but the bug persists. What are three other categories of drift you'd check next?
10. For the disk-full-by-inodes scenario, why does `find / -xdev -printf '%h\n' | sort | uniq -c | sort -rn` help identify the offending directory, and what does the `-xdev` flag protect against?

## Real Interview Questions (Company-Attributed)

- "How will you troubleshoot if a system goes down in Linux — walk through the commands." — asked at *CMT*
- "The date on a VM is behind the current date — how do you fix that?" — asked at *Morgan Stanley*

## Interview Key Points

- The meta-skill being tested in ALL five scenarios: **narrow the search space with cheap, targeted commands before proposing a fix** — jumping straight to "just restart it" without diagnosis is a red flag.
- **Disk full ≠ block usage full**: always check `df -i` (inodes) alongside `df -h` (blocks), and remember deleted-but-open files (`lsof +L1 | grep deleted`) hide "used" space that `du` can't find on disk.
- **Service won't start**: `systemctl status` gives the shape of the failure; `journalctl -xeu <unit>` gives the actual reason. Port conflicts, bad config, permission errors, and missing env files are the four most common root causes to name.
- **High load**: `uptime`/load average tells you *that* something's wrong, not *what*. `vmstat` (check `wa` vs `us`/`sy`) tells you CPU-bound vs I/O-bound, which determines whether your next tool is `iostat`/`iotop` or `top`/`perf`.
- **DNS failures**: work the resolution chain bottom-up — `/etc/resolv.conf` → `dig @<specific-nameserver>` → `ping`/reachability → `/etc/nsswitch.conf` → local caching resolver (`systemd-resolved`) → `/etc/hosts` overrides.
- **"Works on one node, not another"** is almost always **configuration/environment drift**, not app logic — the fix is a systematic diff across packages, config files, unit files, kernel version, and (critically) whether the node was provisioned by the same automation run as its peers.
- Always close with **prevention**, not just the fix: alerting on inode usage, `ionice` for batch jobs, DNS resolver timeout tuning, immutable infra / drift detection — interviewers are listening for this as much as the diagnosis itself.
- Narrate your reasoning out loud in a live interview — the diagnostic *process* (why you ran that command next) is what's being scored, not just arriving at the right answer.
