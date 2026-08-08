# Linux Filesystem Hierarchy Standard (FHS)

The map every Linux system follows for "where does X live" — knowing it cold means you never have to guess where a config, log, or binary should be.

## Explanation

The **Filesystem Hierarchy Standard (FHS)** is a specification (maintained by the Linux Foundation) defining the directory structure and directory contents in Linux systems, so that software, scripts, and admins can rely on predictable locations regardless of distro. Almost every mainstream distro (Debian/Ubuntu, RHEL/Fedora, SUSE) follows it closely, with only minor distro-specific deviations.

The core organizing principles behind FHS are two independent axes:
- **Shareable vs. unshareable**: can this directory's contents be shared over the network with other hosts (e.g., via NFS), or is it host-specific?
- **Static vs. variable**: does the content change without administrator intervention (logs, spool files, caches) or stay fixed until you explicitly reinstall/reconfigure (binaries, libraries, docs)?

### The directories you must know cold

| Path | Purpose | Static/Variable | Shareable? |
|---|---|---|---|
| `/etc` | Host-specific system-wide **configuration files** (`/etc/passwd`, `/etc/fstab`, `/etc/hosts`, `/etc/ssh/sshd_config`) | Static | No (host-specific) |
| `/var` | **Variable data**: logs (`/var/log`), spool/queue data (`/var/spool`), caches, databases that grow at runtime | Variable | Mixed |
| `/usr` | The bulk of installed **user-space programs, libraries, and docs** — think of it as the "read-only, shareable" half of the OS (`/usr/bin`, `/usr/lib`, `/usr/share`, `/usr/local`) | Static | Yes (can be mounted read-only/shared across hosts) |
| `/opt` | **Optional/third-party** self-contained software packages, each typically in its own subdirectory (`/opt/google/chrome`), separate from the distro's own package-managed files | Static | Yes |
| `/proc` | A **virtual/pseudo filesystem** exposing live kernel and process information as "files" — nothing here is on disk, it's generated on-the-fly by the kernel in memory | N/A (virtual) | No |
| `/sys` | Another **virtual filesystem** exposing kernel objects/device driver state (part of the `sysfs`/device-model interface) — used for reading and tuning hardware/kernel parameters | N/A (virtual) | No |
| `/tmp` | **Temporary files**, world-writable (sticky bit set), typically cleared on reboot or by a periodic cleaner (`systemd-tmpfiles`) | Variable, ephemeral | No |
| `/boot` | Files needed to **boot the system**: kernel image (`vmlinuz`), initramfs, GRUB config — everything needed before the root filesystem is fully usable | Static | No |

### `/proc` and `/sys` deserve special attention — they aren't "real" files

Both are **virtual filesystems** with zero on-disk backing — the kernel generates their content live, in-memory, when you read them. This is why `ls -l /proc/*/status` shows file sizes of `0` even though `cat`-ing them produces real output — the kernel computes the content at read-time.
- `/proc/<pid>/` — per-process info (cmdline, environment, open file descriptors, memory maps, status). `/proc/cpuinfo`, `/proc/meminfo`, `/proc/loadavg` are host-wide equivalents that tools like `top`/`free`/`uptime` read from directly.
- `/sys` exposes the kernel's internal **device model** — hardware devices, drivers, and buses as a directory tree, much of it writable to tune live kernel/hardware behavior (e.g., `/sys/class/net/eth0/mtu`, `/sys/block/sda/queue/scheduler`).

Both are *the* interface `/proc`- and `/sys`-aware tools (`ps`, `top`, `free`, `lsblk`, `ethtool`) actually read under the hood — knowing this explains why these tools have (almost) zero performance overhead and always reflect live kernel state.

### `/usr` vs `/opt` vs `/usr/local` — the recurring point of confusion

| Directory | Who manages it | Typical use |
|---|---|---|
| `/usr/bin`, `/usr/lib` | The distro's **package manager** (apt/dnf/zypper) | Anything installed via `apt install` / `dnf install` |
| `/usr/local` | The **local admin**, manually, outside the package manager | Software you compile/install from source yourself, meant to override distro-provided versions |
| `/opt` | **Third-party vendor** software, typically self-contained | Large third-party packages that bundle their own dependencies in one directory tree, not integrated into the distro's package database (e.g., `/opt/splunk`, `/opt/google`) |

**Decision rule: if the package manager installed it, it's under `/usr`. If you built it from source yourself and want it to override the system version, `/usr/local`. If it's a vendor's self-contained bundle you don't want scattered across the OS, `/opt`.** This is the exact distinction interviewers probe for — most candidates can name the directories but can't explain *why* three exist for "extra software."

## Hands-On Examples

**1. Walking the top-level hierarchy**
```bash
$ ls -F /
bin@  boot/  dev/  etc/  home/  lib@  media/  mnt/  opt/  proc/  root/  run/  sbin@  srv/  sys/  tmp/  usr/  var/
```
Modern distros symlink `/bin` → `/usr/bin` and `/lib` → `/usr/lib` (the "usr merge") — legacy paths still work, but everything actually lives under `/usr`.

**2. `/etc` — configuration lives here, and it's genuinely just text**
```bash
$ ls /etc/ssh/
moduli  ssh_config  ssh_config.d  sshd_config  sshd_config.d  ssh_host_ed25519_key  ssh_host_rsa_key

$ grep -v "^#" /etc/fstab
UUID=8f4b2e91-... /               ext4    defaults        0 1
UUID=1a2c3d44-... /boot           ext4    defaults        0 2
/swapfile                         none    swap    sw              0 0
```

**3. `/var` — where logs and runtime data actually accumulate**
```bash
$ du -sh /var/log/* | sort -rh | head -5
128M    /var/log/nginx
64M     /var/log/journal
12M     /var/log/syslog
4.2M    /var/log/auth.log
890K    /var/log/dpkg.log

$ ls /var/spool/
anacron  cron  mail  rsyslog
```
This is exactly why "disk full" incidents almost always trace back to `/var` — it's the one top-level directory that's *designed* to grow unattended (logs, mail spools, package caches).

**4. `/proc` — live kernel/process data, generated on read, zero disk backing**
```bash
$ cat /proc/loadavg
0.52 0.61 0.58 2/891 24103

$ cat /proc/meminfo | head -3
MemTotal:       16332180 kB
MemFree:         2145200 kB
MemAvailable:    9871340 kB

$ ls -l /proc/1/status | head -1
-r--r--r-- 1 root root 0 Aug  8 10:00 /proc/1/status
# ^ size is 0 bytes even though the file has real content — proof it's generated on read, not stored
$ cat /proc/1/status | head -3
Name:   systemd
State:  S (sleeping)
Tgid:   1
```

**5. `/sys` — tuning live kernel/hardware behavior**
```bash
$ cat /sys/class/net/eth0/mtu
1500

$ cat /sys/block/sda/queue/scheduler
noop [mq-deadline] kyber bfq none

$ cat /sys/class/thermal/thermal_zone0/temp
52000
# millidegrees C -> 52.0°C
```

**6. `/tmp` — world-writable with the sticky bit, and why that matters**
```bash
$ ls -ld /tmp
drwxrwxrwt 15 root root 4096 Aug  8 09:00 /tmp
```
The trailing `t` in `drwxrwxrwt` is the **sticky bit** — anyone can create files in `/tmp` (world-writable), but the sticky bit ensures only the file's owner (or root) can delete/rename it, even though the directory itself is writable by everyone. Without the sticky bit, any user could delete any other user's temp files.

**7. `/boot` — what actually gets you from GRUB to a running kernel**
```bash
$ ls /boot/
config-5.15.0-91-generic  grub/  initrd.img-5.15.0-91-generic  System.map-5.15.0-91-generic  vmlinuz-5.15.0-91-generic

$ du -sh /boot
187M    /boot
```
`/boot` filling up (common after many kernel upgrades without cleanup) is a classic real-world incident — `apt autoremove` / `dnf remove --oldinstallonly` clear old kernel images.

**8. Real-world: diagnosing "disk full" by walking FHS-aware directories, not guessing**
```bash
$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1        50G   48G  0.2G  99% /

$ du -sh /var /usr /opt /tmp /home 2>/dev/null | sort -rh
22G     /var
14G     /usr
8.1G    /opt
3.4G    /home
1.2G    /tmp

$ du -sh /var/log/* | sort -rh | head -3
18G     /var/log/journal
2.1G    /var/log/nginx
900M    /var/log/audit
```
Knowing the FHS layout means you check `/var/log` and `/var/spool` *first* on a disk-full incident, rather than randomly `du`-ing the whole tree — this is a textbook example of standards knowledge translating directly into faster incident response.

## Practice Questions

1. What's the practical difference between `/usr`, `/usr/local`, and `/opt`? Give a concrete example of software you'd expect to find in each.
2. Why is `/proc/<pid>/status` reported as 0 bytes by `ls -l` even though `cat`-ing it shows real content?
3. A server's root filesystem is at 99% usage. Based on FHS knowledge alone (before running any commands), which top-level directory would you suspect first, and why?
4. What is the sticky bit on `/tmp` (`drwxrwxrwt`) actually protecting against, given that the directory is world-writable?
5. Explain the difference between `/proc` and `/sys` — both are virtual filesystems, but what kind of information does each expose, and can you write to either to change live kernel/hardware behavior?
6. Why does FHS separate `/etc` (config) from `/var` (variable data) from `/usr` (programs) instead of just having one big directory? What operational benefit does this separation give (hint: think about read-only mounts, network shares, backups).
7. You need to check what MTU is set on a network interface without using `ip` or `ifconfig` — how would you find it directly via the filesystem?
8. A junior engineer deletes everything under `/var/log` to "free up space" on a production box. What could break as a result, beyond just losing log history?
9. What lives in `/boot`, and why can a Linux system fail to boot if `/boot` fills up completely (e.g., from too many retained kernel versions)?
10. Explain why `/usr` is described as "shareable" and "static" in FHS terms — what would it mean, practically, to mount `/usr` read-only or share it over NFS across multiple hosts?

## Real Interview Questions (Company-Attributed)

- "What's inside `/var` and `/opt` in Linux?" — asked at *EPAM*
- "Explain the Linux filesystem hierarchy." — asked at *Verizon*

## Interview Key Points

- **`/proc` and `/sys` are virtual filesystems with no disk backing** — content is generated live by the kernel on read; this single fact explains why `ls -l` shows 0-byte sizes and why tools like `top`/`free`/`ps` are effectively just parsers over these paths.
- **`/var` is the "it grows on its own" directory** — logs, spool, cache — and is the first place to check in almost every "disk full" incident; know this as instinct, not something you have to derive.
- The `/usr` vs `/usr/local` vs `/opt` distinction is a commonly probed "do you actually understand FHS or did you memorize a list" question — the rule is *who* manages the software (package manager vs. you manually vs. a third-party vendor bundle).
- The sticky bit on `/tmp` (`drwxrwxrwt`) is a genuinely important permissions detail — world-writable directory + sticky bit = anyone can create, only the owner/root can delete — a common "explain this permission string" interview probe.
- FHS's "shareable vs unshareable, static vs variable" 2x2 is the actual *design principle* behind the whole standard — quoting this shows you understand the "why," not just the directory list.
- `/boot` filling up from retained old kernel packages is a real, common production issue (especially on frequently-patched Debian/Ubuntu boxes) — worth mentioning as a "seen this in production" answer.
- Modern distros symlink `/bin` → `/usr/bin` and `/lib` → `/usr/lib` (the "usr merge") — legacy top-level paths still work for backward compatibility, but nearly everything now truly lives under `/usr`.
- Know that FHS is a **standard**, not strictly enforced — distros can and do deviate slightly (e.g., where certain app data lives), but core paths (`/etc`, `/var`, `/usr`, `/tmp`, `/boot`, `/proc`, `/sys`, `/opt`) are consistent enough across Debian/RHEL/SUSE families to rely on in scripts and automation.

Sources:
- [Explain the Linux Filesystem Hierarchy (FHS) — Interview Question - Medium](https://medium.com/@sre-devops-interview/explain-the-linux-filesystem-hierarchy-fhs-interview-question-1774f0816302)
- [Filesystem hierarchy standard - Ubuntu project documentation](https://ubuntu.com/project/docs/how-ubuntu-is-made/concepts/filesystem-hierarchy-standard/)
- [Overview of File System Hierarchy Standard (FHS) - Red Hat Documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/5/html/deployment_guide/s1-filesystem-fhs)
- [Filesystem Hierarchy Standard 3.0 - Linux Foundation](https://refspecs.linuxfoundation.org/FHS_3.0/fhs-3.0.html)
