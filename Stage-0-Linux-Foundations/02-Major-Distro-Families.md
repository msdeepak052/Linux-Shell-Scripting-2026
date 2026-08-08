# Major Distro Families: Debian/Ubuntu vs RHEL/CentOS/Rocky/Fedora vs SUSE

Every production Linux box you touch belongs to one of a handful of "families" — knowing the family tells you the package manager, config conventions, and release philosophy before you've even logged in.

## Explanation

A distro **family** is a group of distros that share a package format, package manager lineage, and usually a common ancestor distro. Family membership is what actually determines your day-to-day commands — not the distro's marketing name.

### The three families you must know cold

**1. Debian family** — Debian, Ubuntu, Linux Mint, Kali, Raspberry Pi OS, Pop!_OS.
- Package format: `.deb`. Low-level tool: `dpkg`. High-level dependency-resolving tool: `apt`/`apt-get`.
- Ubuntu is downstream of Debian — it takes Debian's package pool, adds its own patches/branding/release cadence, and ships on a fixed 6-month cycle with LTS releases every 2 years (5+ years of support).
- Config convention: services often configured under `/etc/<service>/`, network historically via `/etc/network/interfaces` (now `netplan` on modern Ubuntu), init via `systemd` on all current releases.
- Philosophy: Debian itself prioritizes stability/free-software purity and has a notoriously conservative release cycle (\"stable\" can ship packages that are a year+ old by design); Ubuntu trades a bit of that conservatism for a more predictable calendar and fresher packages, especially on non-LTS interim releases.

**2. RHEL family (Red Hat lineage)** — RHEL, CentOS (classic, EOL as a rebuild), CentOS Stream, Rocky Linux, AlmaLinux, Fedora, Oracle Linux, Amazon Linux (partially — RPM-based, not a strict RHEL clone).
- Package format: `.rpm`. Low-level tool: `rpm`. High-level tool: `yum` (RHEL/CentOS 7 and earlier) → `dnf` (RHEL/CentOS 8+, Fedora) — `dnf` is `yum`'s successor with a better dependency resolver.
- RHEL is the commercial, subscription-supported product (10-year lifecycle). **Fedora** is RHEL's upstream — it's the fast-moving, bleeding-edge community distro where features get tested before eventually landing in RHEL a version or two later.
- **CentOS** used to be a free, 1:1 rebinary-compatible rebuild of RHEL. In Dec 2020, Red Hat announced classic CentOS would stop and be replaced by **CentOS Stream** — a rolling-preview distro that sits *upstream* of RHEL (between Fedora and RHEL), not a downstream rebuild anymore. This broke the "free RHEL clone" use case.
- **Rocky Linux** and **AlmaLinux** emerged specifically to fill that gap — both are community-driven, 1:1 binary-compatible rebuilds of RHEL (the role classic CentOS used to play). Rocky Linux was founded by CentOS's original creator.
- Config convention: `/etc/sysconfig/` for a lot of service/network config historically, `firewalld` instead of `ufw`, SELinux enabled by default (vs AppArmor on Ubuntu).

**3. SUSE family** — openSUSE (Leap and Tumbleweed) and SUSE Linux Enterprise (SLE/SLES).
- Package format: `.rpm` (same format as RHEL family, but a **different** dependency-resolving tool and repo ecosystem — `.rpm` compatibility does NOT mean cross-distro package compatibility).
- Tool: `zypper` (built on the same low-level `rpm` as RHEL, but `zypper` itself, its repo metadata, and dependency behavior are SUSE-specific — you cannot just `zypper install` a RHEL repo's rpm and expect it to resolve cleanly).
- openSUSE Leap tracks SLE's stable release cadence; openSUSE Tumbleweed is a rolling release (always latest packages, no fixed version numbers).
- Distinctive tooling: **YaST** (Yet another Setup Tool) — a unified system configuration GUI/TUI/CLI tool that's fairly unique to the SUSE ecosystem, used for everything from network config to package management to bootloader setup.
- Less common in general cloud/web infra than Debian or RHEL families, but shows up heavily in specific enterprise contexts (SAP HANA workloads are frequently certified specifically on SLES).

### Which one should you actually use? (Decision rule)

| Scenario | Pick | Why |
|---|---|---|
| General-purpose cloud VM, containers, CI runners, most web infra | **Ubuntu LTS** (Debian family) | Widest package availability, best community/cloud-provider support, predictable LTS cadence, default choice on AWS/GCP/Azure marketplace images |
| Enterprise workload needing vendor support/compliance (finance, healthcare, government) | **RHEL** (paid) or **Rocky/AlmaLinux** (free RHEL-compatible) | RHEL for guaranteed vendor SLA + certified hardware/software stacks; Rocky/Alma when you need RHEL binary compatibility without the subscription cost |
| You want to track the bleeding edge / contribute upstream features destined for RHEL | **Fedora** | Fedora is explicitly RHEL's testing ground — new kernel features, toolchains, and packages land there first |
| SAP HANA, or an enterprise mandates SUSE specifically | **SLES** | Certified/preferred for specific enterprise workloads (SAP is the big one) |
| You just want to learn Debian-family package management day to day, minimal footprint | **Debian stable** itself | More conservative/stable than Ubuntu, no Canonical-specific patches, common on minimal servers/containers |

**Bottom line: default to Ubuntu LTS or Debian for general infra (best ecosystem support, `apt`), reach for RHEL/Rocky/Alma (`dnf`) when the environment specifically demands RHEL compatibility or enterprise support, and know SUSE (`zypper`) exists mainly for SAP/enterprise-specific mandates — in an interview, naming this decision tree unprompted is a strong signal.**

### Command-equivalence cheat sheet (memorize this table)

| Task | Debian/Ubuntu | RHEL/Fedora/Rocky | SUSE |
|---|---|---|---|
| Install a package | `apt install nginx` | `dnf install nginx` | `zypper install nginx` |
| Remove a package | `apt remove nginx` | `dnf remove nginx` | `zypper remove nginx` |
| Update all packages | `apt update && apt upgrade` | `dnf update` | `zypper update` |
| Search for a package | `apt search nginx` | `dnf search nginx` | `zypper search nginx` |
| Query installed package info | `dpkg -l \| grep nginx` | `rpm -qa \| grep nginx` | `rpm -qa \| grep nginx` |
| List files owned by a package | `dpkg -L nginx` | `rpm -ql nginx` | `rpm -ql nginx` |
| Firewall tool | `ufw` | `firewalld` | `firewalld` / SuSEfirewall2 |
| Mandatory access control | AppArmor | SELinux | AppArmor |
| Default init system (modern releases) | systemd | systemd | systemd |

## Hands-On Examples

**1. Identifying which family you're on, portably**
```bash
$ cat /etc/os-release
NAME="Ubuntu"
VERSION="22.04.3 LTS (Jammy Jellyfish)"
ID=ubuntu
ID_LIKE=debian
```
```bash
$ cat /etc/os-release
NAME="Rocky Linux"
VERSION="9.2 (Blue Onyx)"
ID="rocky"
ID_LIKE="rhel centos fedora"
```
The `ID_LIKE` field is the reliable, script-friendly way to detect the *family*, not just the specific distro — always parse `/etc/os-release`, never `uname` or hostname conventions, for family detection in automation.

**2. Installing the same package across families**
```bash
# Ubuntu
$ sudo apt update && sudo apt install -y htop
Reading package lists... Done
The following NEW packages will be installed: htop
Setting up htop (3.0.5-7build2) ...

# Rocky Linux
$ sudo dnf install -y htop
Last metadata expiration check: 0:12:44 ago.
Installed:
  htop-3.2.1-3.el9.x86_64

# openSUSE
$ sudo zypper install -y htop
Retrieving: htop-3.2.2-1.2.x86_64.rpm ...
Installation of htop-3.2.2-1.2.x86_64 finished.
```

**3. Querying what package owns a file — dpkg vs rpm**
```bash
# Ubuntu: which package owns /usr/bin/nginx?
$ dpkg -S /usr/sbin/nginx
nginx-core: /usr/sbin/nginx

# RHEL/Rocky: same question
$ rpm -qf /usr/sbin/nginx
nginx-1.20.1-14.el9.x86_64
```

**4. The "same .rpm format ≠ compatible packages" trap between RHEL and SUSE**
```bash
$ file custom-tool-1.0-1.el9.x86_64.rpm
custom-tool-1.0-1.el9.x86_64.rpm: RPM v3.0 bin i386/x86_64

$ sudo zypper install ./custom-tool-1.0-1.el9.x86_64.rpm
Problem: nothing provides 'libssl.so.1.1()(64bit)' needed by custom-tool-1.0-1.el9.x86_64
Solution: do not install custom-tool-1.0-1.el9.x86_64
```
Both are `.rpm`, but the RHEL-built package expects RHEL's library versions/paths — SUSE's base libraries differ enough that direct cross-installation frequently fails. RPM format compatibility is NOT distro compatibility.

**5. Checking SELinux (RHEL family) vs AppArmor (Ubuntu) status — a real troubleshooting divergence**
```bash
# Rocky/RHEL
$ getenforce
Enforcing
$ sudo ausearch -m avc -ts recent | tail -3
type=AVC msg=audit(1723123456.789:245): avc: denied { write } for pid=4521 comm="nginx" ...

# Ubuntu
$ sudo aa-status | head -5
apparmor module is loaded.
15 profiles are loaded.
12 profiles are in enforce mode.
   /usr/sbin/nginx
```
A "permission denied" that makes no sense against normal Unix file permissions is a classic sign of SELinux (RHEL family) or AppArmor (Ubuntu) blocking the action — knowing which MAC system your distro family uses saves serious debugging time.

**6. Detecting CentOS's actual status — a real "gotcha" you'll hit in the wild**
```bash
$ cat /etc/os-release
NAME="CentOS Stream"
VERSION="9"
ID="centos"
ID_LIKE="rhel fedora"
```
If you see `CentOS Stream` (not classic `CentOS Linux`), this box is running a rolling, upstream-of-RHEL distro — NOT the stable rebuild that classic CentOS used to be. This distinction matters operationally: Stream gets updates *before* RHEL does, which is the opposite stability posture from what "CentOS" used to imply pre-2020.

**7. Real scenario: a Terraform/Ansible playbook that must branch on distro family**
```bash
$ cat detect_family.sh
#!/bin/bash
. /etc/os-release
case "$ID_LIKE" in
    *debian*) pkg_mgr="apt" ;;
    *rhel*|*fedora*) pkg_mgr="dnf" ;;
    *suse*) pkg_mgr="zypper" ;;
    *) echo "Unknown family, ID=$ID" >&2; exit 1 ;;
esac
echo "Using package manager: $pkg_mgr"

$ ./detect_family.sh
Using package manager: dnf
```
This is the standard defensive pattern in real automation (Ansible's `ansible_os_family` fact does effectively this) — never hardcode `apt` in a script meant to run across a fleet with mixed distros.

## Practice Questions

1. What actually happened to CentOS in December 2020, and what two distros emerged specifically to fill the gap it left? What role does each play relative to RHEL now?
2. Explain the relationship between Fedora, CentOS Stream, and RHEL — which is upstream of which?
3. You SSH into an unfamiliar box and need to know whether to use `apt` or `dnf` before touching anything. What's the single most reliable file/field to check, and why is checking for the presence of a binary like `which apt` a worse approach?
4. Both RHEL and openSUSE use the `.rpm` package format. Does that mean an `.rpm` built for RHEL 9 will install cleanly on openSUSE Leap? Explain why or why not.
5. What's the difference between `yum` and `dnf`? Why did the RHEL ecosystem move to `dnf`?
6. A teammate says "just use CentOS, it's free RHEL." Is that still an accurate statement in 2026? What would you correct?
7. Compare Ubuntu's LTS release model to Debian's stable release model — which tends to have "fresher" packages and why might a platform team pick one over the other?
8. Your Ansible playbook needs to install a package across a fleet with a mix of Ubuntu and Rocky Linux hosts. Write the logic (conceptually or as a script snippet) to select the right package manager per host.
9. What Mandatory Access Control system does RHEL/Rocky use by default, versus what Ubuntu uses? How would the troubleshooting commands differ if a legitimately-permissioned process still gets "Permission denied"?
10. Why might an enterprise specifically mandate SUSE Linux Enterprise Server over RHEL or Ubuntu for a particular workload? Name a concrete example.

## Interview Key Points

- **CentOS's 2020 shift is one of the most commonly tested "do you keep up with the ecosystem" questions** — know that classic CentOS (downstream rebuild) is dead, CentOS Stream is now upstream-of-RHEL (rolling/preview), and Rocky Linux/AlmaLinux are the community successors that took over CentOS's old role.
- **Fedora → CentOS Stream → RHEL** is the correct upstream-to-downstream feature flow in the modern Red Hat ecosystem — Fedora is the fastest-moving/most bleeding-edge, RHEL is the slowest/most stable.
- Same package **format** (`.rpm`) does not imply cross-distro **compatibility** — RHEL-family and SUSE both use rpm but have separate repos, library versions, and dependency ecosystems; this is a great "gotcha" to bring up unprompted.
- `ID_LIKE` in `/etc/os-release` is the correct, script-safe way to detect distro family for automation — senior candidates should know this over fragile alternatives (checking for specific binaries, parsing `uname`).
- Know the MAC (Mandatory Access Control) divergence: **SELinux is default/native to RHEL family**, **AppArmor is default/native to Ubuntu/SUSE** — "permission denied despite correct chmod/chown" is the classic symptom that should make you check these before anything else.
- `yum` → `dnf` is RHEL 8+/Fedora's package manager evolution — dnf has better dependency resolution and is a near drop-in replacement (many `dnf` commands accept old `yum` syntax).
- SUSE is a smaller footprint in general cloud infra but has a real enterprise niche (especially SAP HANA-certified deployments) — worth knowing it exists and why, even without hands-on daily use.
- Debian itself (not just Ubuntu) is common as a minimal container base image and on servers where maximal stability/free-software purity matters more than release cadence — don't conflate "Debian family" with "Ubuntu" only.

Sources:
- [Linux vs Unix vs Distro: Ubuntu, Debian, RHEL, Fedora and Arch Explained](https://www.golinuxcloud.com/linux-unix-distro-ubuntu-debian-rhel-fedora-arch/)
- [Fedora Project Wiki: Comparison to other distributions](https://fedoraproject.org/wiki/Comparison_to_other_distributions)
- [Linux Interview Questions and Answers for 2 years experience (2026) - HelloIntern](https://blog.hellointern.in/linux-interview-questions-and-answers-for-2-years-experience-96656)
