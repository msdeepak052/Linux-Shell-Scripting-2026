# Package Management: `apt`/`dpkg` vs `yum`/`dnf`/`rpm`

Every Linux distro splits package management into a low-level tool (installs/queries individual package files, no dependency resolution) and a high-level tool (talks to repositories, resolves dependencies). Knowing both layers — and the RPM-family/Debian-family equivalents — is baseline sysadmin/SRE knowledge.

## Explanation

### Two layers, both families

| Layer | Debian family | RHEL family |
|---|---|---|
| Low-level (single `.deb`/`.rpm` file, no dependency resolution) | `dpkg` | `rpm` |
| High-level (repos, dependency resolution, remote fetch) | `apt` / `apt-get` / `apt-cache` | `yum` (older) / `dnf` (modern, RHEL8+/Fedora/CentOS Stream) |
| Package file format | `.deb` | `.rpm` |
| Repo metadata | `/etc/apt/sources.list`, `/etc/apt/sources.list.d/*.list` | `/etc/yum.repos.d/*.repo` |
| Local package cache | `/var/cache/apt/archives/` | `/var/cache/dnf/` or `/var/cache/yum/` |

### Debian family: `dpkg` + `apt`

**`dpkg`** — operates on a single, already-downloaded `.deb` file. No network, no dependency resolution (it will complain about missing deps but not fetch them).
```bash
dpkg -i package.deb        # install a local .deb
dpkg -r package             # remove (keeps config files)
dpkg -P package              # purge (removes config files too)
dpkg -l                      # list installed packages
dpkg -L package               # list files a package installed
dpkg -S /path/to/file          # which package owns this file
dpkg --configure -a            # fix a half-configured package (common after interrupted installs)
```

**`apt`** (modern front-end over `apt-get`/`apt-cache`, since ~2016) — repo-aware, resolves and fetches dependencies.
```bash
apt update                    # refresh package index (NOT upgrade — a common confusion point)
apt upgrade                   # upgrade installed packages, won't remove packages to resolve deps
apt full-upgrade              # like upgrade but WILL remove packages if needed to resolve deps (was dist-upgrade)
apt install pkg=1.2.3-1        # install a specific version (pin)
apt remove pkg                  # remove, keep config
apt purge pkg                    # remove including config files
apt autoremove                    # remove orphaned dependencies no longer needed
apt search keyword                  # search package names/descriptions
apt show pkg                         # detailed package info
apt list --installed                  # list installed packages
apt list --upgradable                  # what's outdated
apt-cache policy pkg                    # show installed vs candidate version, and which repo it'd come from
```

### RHEL family: `rpm` + `yum`/`dnf`

**`rpm`** — like `dpkg`, operates on a single `.rpm` file, no dependency resolution or network access.
```bash
rpm -ivh package.rpm         # install, verbose, hash progress
rpm -Uvh package.rpm          # upgrade (or install if not present)
rpm -e package                  # erase/remove
rpm -qa                          # list all installed packages
rpm -qf /path/to/file              # which package owns this file
rpm -ql package                     # list files owned by a package
rpm -qi package                      # package info
rpm -q --changelog package             # changelog
rpm -Va                                 # verify all installed packages (checksums, perms) — integrity audit
```

**`yum`/`dnf`** — repo-aware, dependency-resolving. `dnf` is the modern successor to `yum` (RHEL 8+, Fedora, CentOS Stream, Rocky/Alma) — mostly command-compatible, `yum` is often just a symlink to `dnf` on newer systems.
```bash
dnf check-update                # like apt update, just checks (doesn't modify local cache the way apt does)
dnf install pkg
dnf update                       # update all, or dnf update pkg for one package
dnf remove pkg
dnf search keyword
dnf info pkg
dnf provides */bin/somefile        # find which package provides a file/binary (like dpkg -S / rpm -qf but repo-wide)
dnf list installed
dnf history                          # transaction history — powerful, supports rollback
dnf history undo <id>                  # roll back a specific transaction
dnf repolist                             # list configured/enabled repos
dnf clean all                             # clear cached metadata/packages
```

### Key cross-family concepts

- **Dependency hell** (`dpkg`/`rpm` alone) vs **automatic resolution** (`apt`/`dnf`) — this is the core reason the two-layer design exists.
- **Held/locked packages** — prevent accidental upgrade of a specific package:
  - Debian: `apt-mark hold pkg` / `apt-mark unhold pkg`
  - RHEL: `dnf install python3-dnf-plugin-versionlock` then `dnf versionlock add pkg`
- **Repository priority/pinning** — Debian: `/etc/apt/preferences.d/`; RHEL: repo `priority=` in `.repo` files, or `includepkgs=`/`excludepkgs=`.
- **GPG signature verification** — both families verify package signatures against trusted keys by default (`apt-key`/`trusted.gpg.d` historically, now `signed-by=` in source entries; RPM's embedded signature checked against imported keys in the RPM DB).
- **`dnf history undo`** has no direct `apt` equivalent — `apt` has no built-in transaction rollback; you'd need `apt-get install pkg=<old-version>` manually or a snapshot tool (timeshift, etc.).
- **Broken/half-installed state recovery**: Debian `sudo dpkg --configure -a && sudo apt --fix-broken install`; RHEL `sudo rpm -Va` to find issues, `sudo dnf reinstall pkg` to fix.

## Hands-On Examples

**1. Standard Debian install workflow**
```bash
$ sudo apt update
Hit:1 http://archive.ubuntu.com/ubuntu jammy InRelease
Get:2 http://archive.ubuntu.com/ubuntu jammy-updates InRelease [128 kB]
Reading package lists... Done

$ sudo apt install nginx
The following additional packages will be installed:
  libnginx-mod-http-image-filter nginx-common nginx-core
Need to get 1,203 kB of archives.
After this operation, 3,882 kB of additional disk space will be used.
Do you want to continue? [Y/n] y
Setting up nginx (1.18.0-6ubuntu14.4) ...
```

**2. Finding which package owns a binary / file (Debian)**
```bash
$ which nginx
/usr/sbin/nginx
$ dpkg -S /usr/sbin/nginx
nginx-core: /usr/sbin/nginx

$ dpkg -l | grep nginx
ii  nginx          1.18.0-6ubuntu14.4  all   small, powerful, scalable web/proxy server
ii  nginx-core     1.18.0-6ubuntu14.4  amd64 nginx web/proxy server (core module)
```

**3. Installing a locally downloaded `.deb` and fixing missing dependencies**
```bash
$ sudo dpkg -i custom-tool_2.3.0_amd64.deb
dpkg: dependency problems prevent configuration of custom-tool:
 custom-tool depends on libfoo2 (>= 1.4); however: Package libfoo2 is not installed.
dpkg: error processing package custom-tool (--configure):
 dependency problems - leaving unconfigured

$ sudo apt --fix-broken install
Reading package lists... Done
The following additional packages will be installed: libfoo2
Setting up libfoo2 (1.4.2-1) ...
Setting up custom-tool (2.3.0) ...
```

**4. RHEL/dnf equivalent install + query workflow**
```bash
$ sudo dnf install httpd
Last metadata expiration check: 0:12:04 ago.
Dependencies resolved.
================================================================
 Package    Arch     Version              Repository      Size
================================================================
Installing:
 httpd      x86_64   2.4.57-5.el9         appstream      1.5 M
Complete!

$ rpm -qa | grep httpd
httpd-2.4.57-5.el9.x86_64

$ dnf provides */bin/httpd
httpd-2.4.57-5.el9.x86_64 : Apache HTTP Server
```

**5. Holding a package at its current version to avoid an unwanted upgrade**
```bash
# Debian
$ sudo apt-mark hold nginx
nginx set on hold.
$ sudo apt upgrade
# nginx is skipped even if a newer version is available
$ sudo apt-mark unhold nginx

# RHEL
$ sudo dnf install -y python3-dnf-plugin-versionlock
$ sudo dnf versionlock add httpd
$ sudo dnf update
# httpd stays at locked version
```

**6. `dnf history` — transaction log and rollback (no direct apt equivalent)**
```bash
$ dnf history
ID     | Command line             | Date and time    | Action(s)  | Altered
-----------------------------------------------------------------------
   14   | update httpd              | 2026-08-08 09:12 | Upgrade     |    1
   13   | install nginx-mod-http     | 2026-08-07 14:03 | Install     |    2

$ sudo dnf history undo 14
Undoing transaction 14, from Sat 08 Aug 2026 09:12:00 AM UTC
    Upgrade httpd-2.4.58-1.el9.x86_64
Is this ok [y/N]: y
```

**7. Cleaning up orphaned dependencies and cache**
```bash
$ sudo apt autoremove --purge
The following packages will be REMOVED:
  libfoo2* linux-headers-5.15.0-91*
0 upgraded, 0 newly installed, 2 to remove
Freed 214 MB disk space.

$ sudo apt clean       # clear /var/cache/apt/archives entirely

$ sudo dnf autoremove
$ sudo dnf clean all
```

**8. Verifying package integrity (useful in a security audit / drift investigation)**
```bash
$ rpm -V httpd
S.5....T.  c /etc/httpd/conf/httpd.conf
# S=size, 5=checksum, T=mtime changed; c=config file — flags that httpd.conf was manually modified

$ dpkg -V nginx
??5?????? c /etc/nginx/nginx.conf
# similar — verifies against recorded checksums, ?? means info unavailable (common on Debian, less complete than rpm -V)
```

## Practice Questions

1. Explain the difference between `dpkg`/`rpm` and `apt`/`dnf` — why do both layers exist instead of just one tool?
2. What's the difference between `apt update` and `apt upgrade`? What real-world mistake does confusing them cause?
3. You have a `.deb` file with unmet dependencies. Walk through installing it and resolving the dependency error.
4. How do you find which installed package owns a specific file, in both Debian and RHEL families?
5. What does `apt full-upgrade` (or `dist-upgrade`) do differently from a plain `apt upgrade`, and when would you need it?
6. How do you prevent a specific package from being upgraded during routine maintenance, on both a Debian and an RHEL system?
7. Explain `dnf history` and `dnf history undo`. Why doesn't `apt` have a direct equivalent, and what would you do on Debian to achieve something similar?
8. A production RHEL box has a config file you suspect was manually edited outside of configuration management. How would you use `rpm -V` to confirm this?
9. What's the difference between `apt remove` and `apt purge`? When does it matter in practice?
10. You're auditing a server and need a full list of installed packages with versions, exportable for comparison against a baseline. Give the command for both a Debian and an RHEL system.

## Real Interview Questions (Company-Attributed)

- "If a VM is deployed in a private subnet, how do you perform patch updates like `apt update`?" — asked at *Qburst*

## Interview Key Points

- Know the **two-layer architecture** cold: low-level (`dpkg`/`rpm`, single file, no dep resolution) vs high-level (`apt`/`dnf`, repo-aware, resolves deps) — this maps directly across both families and is a very common "explain package management" opener.
- `apt update` != `apt upgrade` — refreshing the index vs actually upgrading packages — an extremely common real-world and interview mix-up.
- `dnf history undo` is a distinguishing RHEL-family feature with no direct Debian equivalent — worth citing when asked to compare the two ecosystems.
- Know the file-ownership lookup commands (`dpkg -S`, `rpm -qf`) — a bread-and-butter "which package installed this binary" incident-response skill.
- `apt --fix-broken install` / `dpkg --configure -a` for Debian, `rpm -Va` / `dnf reinstall` for RHEL — recovery from a half-installed/broken package state is a realistic on-call scenario.
- Holding/version-locking packages (`apt-mark hold`, `dnf versionlock`) is relevant to any "how do you prevent an unwanted upgrade from breaking prod" question.
- `rpm -Va` / `dpkg -V` verify installed files against recorded checksums/permissions — useful for detecting configuration drift or unauthorized changes, a security-adjacent skill worth mentioning proactively.
- Repository configuration lives in `/etc/apt/sources.list(.d/)` vs `/etc/yum.repos.d/*.repo` — know where to look when a package can't be found or comes from an unexpected source.
