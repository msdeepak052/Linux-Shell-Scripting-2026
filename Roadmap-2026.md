# Linux & Shell Scripting Roadmap 2026
### For Senior Platform Engineering (Beginner → Intermediate → Advanced → Expert)

A chronological, progressive checklist covering Linux systems and Shell (Bash) scripting, shaped for day-to-day Platform Engineering work — heavy emphasis on production troubleshooting, automation, and scripting since that's the core daily toolset at senior level. Distro coverage is general (Ubuntu/Debian and RHEL/Fedora families) with cloud/container context woven into the later stages.

---

## Stage 0 — Linux Foundations
*Absolute basics: what you're actually operating on.*

- [ ] What is Linux — kernel vs OS vs distro
- [ ] Major distro families: Debian/Ubuntu vs RHEL/CentOS/Rocky/Fedora vs SUSE (know the differences, not just one)
- [ ] Linux Filesystem Hierarchy Standard (FHS) — `/etc`, `/var`, `/usr`, `/opt`, `/proc`, `/sys`, `/tmp`, `/boot`
- [ ] Boot process overview: BIOS/UEFI → GRUB → kernel → init/systemd
- [ ] Shells overview: bash vs sh vs zsh, what a shell actually is
- [ ] Basic navigation: `pwd`, `cd`, `ls`, `mkdir`, `rmdir`, `touch`, `cp`, `mv`, `rm`
- [ ] Viewing files: `cat`, `less`, `more`, `head`, `tail`, `tail -f`
- [ ] Getting help: `man`, `info`, `--help`, `tldr`, `apropos`

## Stage 1 — Core CLI Skills
*The commands you'll type hundreds of times a day.*

- [ ] File permissions & ownership: `chmod`, `chown`, `chgrp`, octal vs symbolic notation
- [ ] Special permissions: SUID, SGID, sticky bit
- [ ] `umask` and default permission behavior
- [ ] Users & groups: `useradd`, `usermod`, `userdel`, `groupadd`, `passwd`, `/etc/passwd`, `/etc/shadow`, `/etc/group`
- [ ] Text processing basics: `grep`, `cut`, `sort`, `uniq`, `tr`, `wc`
- [ ] Intro `sed` and `awk` (single-line usage)
- [ ] Searching: `find`, `locate`, `which`, `whereis`, `type`
- [ ] Archiving & compression: `tar`, `gzip`, `bzip2`, `xz`, `zip`/`unzip`
- [ ] I/O redirection & pipes: `>`, `>>`, `<`, `|`, `2>`, `2>&1`, `tee`
- [ ] Wildcards & globbing: `*`, `?`, `[]`, brace expansion `{}`

## Stage 2 — Process & System Management
*Keeping services alive and understanding what the system is doing.*

- [ ] Process fundamentals: `ps`, `ps aux`, `top`, `htop`
- [ ] Process states, PID/PPID, foreground vs background
- [ ] Signals & killing processes: `kill`, `killall`, `pkill`, signal numbers (SIGTERM/SIGKILL/SIGHUP)
- [ ] Priority control: `nice`, `renice`
- [ ] Job control: `jobs`, `fg`, `bg`, `&`, `nohup`, `disown`
- [ ] systemd fundamentals: units, targets, `systemctl start/stop/enable/status`
- [ ] Writing/understanding a custom systemd unit file
- [ ] `journalctl` — reading and filtering logs
- [ ] Scheduling: `cron`, `crontab -e`, cron syntax, `at`, systemd timers
- [ ] Package management: `apt`/`dpkg` (Debian family) vs `yum`/`dnf`/`rpm` (RHEL family)
- [ ] Log management: `/var/log`, `rsyslog`, `logrotate`

## Stage 3 — Filesystem & Storage
*What happens when disks fill up or need resizing.*

- [ ] Disk/partition basics: `lsblk`, `fdisk`, `parted`
- [ ] Filesystem types: ext4, xfs, btrfs — when each is used
- [ ] Creating & mounting filesystems: `mkfs`, `mount`, `umount`, `/etc/fstab`
- [ ] LVM: physical volumes, volume groups, logical volumes (`pvcreate`, `vgcreate`, `lvcreate`, `lvextend`)
- [ ] Disk usage analysis: `df -h`, `du -sh`, `ncdu`
- [ ] Inode exhaustion vs actual disk-space exhaustion (classic "disk full but df shows space" scenario)
- [ ] Swap: creating/enabling swap, swappiness
- [ ] RAID basics: `mdadm`, RAID levels overview
- [ ] Disk/filesystem quotas

## Stage 4 — Networking
*Every platform engineering task eventually touches the network.*

- [ ] TCP/IP fundamentals, OSI model (high level)
- [ ] Interface configuration: `ip addr`, `ip route`, `nmcli`, `netplan` (Ubuntu) vs `NetworkManager`/`nmtui` (RHEL)
- [ ] DNS resolution: `/etc/resolv.conf`, `/etc/hosts`, `dig`, `nslookup`, `host`
- [ ] Ports & sockets: `ss`, `netstat`, listening vs established connections
- [ ] Firewalls: `iptables`, `nftables`, `firewalld`, `ufw`
- [ ] SSH: key-based auth, `ssh-agent`, `~/.ssh/config`, port forwarding/tunneling, `scp`, `rsync`
- [ ] Network troubleshooting: `ping`, `traceroute`/`mtr`, `curl`, `wget`, `tcpdump`, `nc`/`ncat`, `telnet`
- [ ] Reverse proxy & load balancer awareness: nginx, HAProxy basics
- [ ] MTU, routing tables, and basic packet-flow debugging

## Stage 5 — Security & Hardening
*Locking systems down and knowing what "least privilege" actually looks like.*

- [ ] `sudo` and `/etc/sudoers` (visudo, sudoers.d)
- [ ] SELinux (RHEL) and AppArmor (Ubuntu) — modes, contexts, troubleshooting denials
- [ ] SSH hardening: disabling root login, key-only auth, fail2ban
- [ ] File integrity & auditing: `auditd`, `aide`
- [ ] TLS/certificates basics: `openssl` commands (generate keys/certs, verify, inspect)
- [ ] Secrets handling in shell environments (avoiding plaintext secrets, env var hygiene, vault/secret-manager CLIs)
- [ ] Linux capabilities vs full root (`setcap`, `getcap`)
- [ ] Security patching workflow and CVE awareness at the OS package level

## Stage 6 — Shell Scripting Fundamentals (Bash)
*Writing your first real scripts.*

- [ ] Shebang line, script permissions, execution (`./script.sh` vs `bash script.sh`)
- [ ] Variables, quoting rules (single vs double vs backtick), `$()` command substitution
- [ ] Special variables: `$0`, `$1..$9`, `$@`, `$*`, `$#`, `$?`, `$$`, `$!`
- [ ] Reading input: `read`, here-strings
- [ ] Conditionals: `if/elif/else`, `case`, `[ ]` vs `[[ ]]` vs `(( ))`
- [ ] Loops: `for`, `while`, `until`, `break`/`continue`
- [ ] Functions: definition, arguments, return values, local vs global scope
- [ ] Arrays: indexed and associative arrays
- [ ] Exit codes and basic error checks (`$?`, `||`, `&&`)
- [ ] String manipulation & parameter expansion (`${var:-default}`, `${var#pattern}`, substrings, length)

## Stage 7 — Advanced Shell Scripting
*Scripts that don't fall over in production.*

- [ ] Advanced `sed`/`awk` scripting (multi-command scripts, in-place edits, field processing)
- [ ] Regular expressions: BRE vs ERE, `grep -E`, `grep -P`
- [ ] Here-docs (`<<EOF`) and process substitution (`<(...)`, `>(...)`)
- [ ] Robust error handling: `set -e`, `set -u`, `set -o pipefail`, `trap` for cleanup on exit/signal
- [ ] Writing idempotent scripts (safe to re-run without side effects)
- [ ] Argument parsing: `getopts`, handling flags and long options
- [ ] Debugging: `bash -x`, `set -x`/`set +x`, `shellcheck` static analysis
- [ ] Parallelism: `wait`, `xargs -P`, GNU `parallel`
- [ ] Structured logging from scripts (timestamps, log levels, log-to-file patterns)
- [ ] Locking to prevent concurrent script execution (`flock`)

## Stage 8 — Production-Grade Scripting & Automation (Senior/Platform Engineering Focus)
*Where senior-level signal actually lives — this is the daily-driver stage.*

- [ ] Health-check, monitoring, and alerting scripts (CPU/memory/disk/service checks)
- [ ] Backup, cleanup, and log-rotation automation scripts
- [ ] Reliable cron/systemd-timer integration for scheduled automation
- [ ] Team script standards: consistent structure, usage/help text, exit-code conventions
- [ ] JSON/YAML parsing in shell: `jq`, `yq`
- [ ] Cloud CLI scripting: `aws`, `gcloud`, `az` invoked from Bash, output parsing
- [ ] Wrapper/orchestration scripts around Terraform, Ansible, `kubectl`, Helm
- [ ] CI/CD shell scripting patterns (Jenkins, GitLab CI, GitHub Actions build/deploy steps)
- [ ] Container & Kubernetes debugging from the shell: `docker exec`, `kubectl exec`, `kubectl logs`, `crictl`
- [ ] Container-host internals awareness: namespaces, cgroups, `nsenter`
- [ ] Kernel/runtime tuning: `sysctl`, `ulimit`, reading `/proc` and `/sys`
- [ ] Troubleshooting methodology: high CPU, disk "full" but `df` looks fine (inodes), zombie/defunct processes, OOM killer investigation (`dmesg`, `/var/log/messages`)
- [ ] Boot & recovery: single-user/rescue mode, GRUB recovery, fixing a system that won't boot
- [ ] Performance baselining: `vmstat`, `iostat`, `sar`, `dstat`

## Stage 9 — Expert & Interview Readiness
*Polishing the skill set for senior-level scenarios and system thinking.*

- [ ] SLI/SLO-aware thinking applied to scripts and health checks
- [ ] Writing runbooks and incident-response automation
- [ ] Shell's role inside larger IaC/deployment pipelines (glue code between tools)
- [ ] Common senior scenario topics: disk full but not full, service won't start, sudden high load, DNS resolution failure, "it works on one node but not another"
- [ ] Testing shell scripts: `bats`, `shunit2`
- [ ] Style & maintainability: Google Shell Style Guide, code review practices for scripts
- [ ] Documenting and version-controlling operational scripts (treating scripts as real code)

---

**How to use this**: Work top to bottom for a first pass. Stages 0–5 are Linux systems knowledge; Stages 6–9 are shell scripting, moving from syntax to production automation. For senior/Platform Engineering interview prep specifically, prioritize Stages 2–5 (troubleshooting depth) and Stages 8–9 (production automation + scenario thinking) — that's where senior signal is actually evaluated.
