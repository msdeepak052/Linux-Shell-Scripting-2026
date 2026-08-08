# Boot Process Overview: BIOS/UEFI → GRUB → Kernel → Init/systemd

The sequence of events between "power on" and "login prompt" — and the stage-by-stage map you need when a box won't come back up.

## Explanation

Booting Linux is a **hand-off chain**: each stage does the minimum needed to load and transfer control to the next, progressively more capable stage. Knowing the chain in order is exactly what lets you localize a boot failure to the right stage instead of guessing.

### The stages, in order

**1. Firmware — BIOS or UEFI**
The very first code that runs when you power on, built into the motherboard. Its job: run POST (Power-On Self-Test) to check hardware, then locate and hand off to a bootloader.
- **BIOS** (legacy): reads the **MBR** (Master Boot Record) — the first 512 bytes of the boot disk — which contains a tiny first-stage bootloader. Works with **MBR** partition tables (max ~2TB disks, max 4 primary partitions).
- **UEFI** (modern standard): reads boot entries from an **EFI System Partition (ESP)** — a small FAT32 partition containing `.efi` bootloader executables. Works with **GPT** partition tables (no practical disk-size limit, many more partitions). UEFI also supports **Secure Boot** — cryptographically verifying the bootloader/kernel signature chain before executing it.

**2. Bootloader — GRUB (GRUB2 on virtually all modern distros)**
GRUB's job is narrow but critical: present a boot menu (if configured), locate the kernel image and initramfs on disk, load both into memory, and execute the kernel — passing it boot parameters (like which partition is root, kernel command-line options).
- Config: `/boot/grub/grub.cfg` (generated — you don't hand-edit it) built from `/etc/default/grub` + scripts in `/etc/grub.d/`, regenerated via `update-grub` (Debian/Ubuntu) or `grub2-mkconfig` (RHEL family).
- GRUB itself has two install locations depending on firmware: written to the MBR boot sector for BIOS systems, or installed as an `.efi` binary on the ESP for UEFI systems.

**3. Kernel initialization**
Once GRUB hands off, the kernel decompresses itself into memory, initializes core subsystems (memory management, scheduler), and loads an **initramfs** (initial RAM filesystem) — a small temporary root filesystem in memory containing just enough drivers/tools (e.g., disk controller drivers, LVM/RAID tools, encryption unlocking) to find and mount the **real** root filesystem. Once the real root is mounted, the kernel switches to it (`pivot_root`/`switch_root`) and discards the initramfs.

**4. Init system — systemd (or legacy sysvinit/upstart)**
The kernel starts exactly one process as **PID 1** — on virtually all modern distros, that's `systemd`. PID 1's job is to bring the rest of userspace up: mount remaining filesystems, start system services in dependency order, bring up networking, eventually present a login (console or display manager).
- systemd organizes work into **units** (service units, mount units, target units, socket units, timer units, etc.) and **targets** (roughly analogous to old SysV "runlevels" — e.g., `multi-user.target` ≈ old runlevel 3, `graphical.target` ≈ old runlevel 5).
- Legacy sysvinit (`/etc/inittab`, numbered runlevels 0-6, `/etc/rc.d/`) still shows up in older systems, embedded devices, or specific minimal distros (Alpine uses OpenRC) — know it exists, but systemd is what you'll actually operate on modern RHEL/Ubuntu/SUSE.

### The full chain, visually

```
Power on
  → Firmware POST (BIOS or UEFI)
      → Bootloader: GRUB2 (reads /boot/grub/grub.cfg)
          → Loads kernel (vmlinuz) + initramfs into RAM
              → Kernel boots, mounts initramfs as temp root
                  → initramfs finds/mounts real root filesystem
                      → Kernel switch_root's into real root
                          → Kernel execs PID 1 = systemd (or init)
                              → systemd starts units toward default.target
                                  → login prompt / display manager
```

### BIOS vs UEFI — which matters where (Decision rule)

| Aspect | BIOS (legacy) | UEFI (modern) |
|---|---|---|
| Partition table required | MBR (max 2TB, 4 primary partitions) | GPT (huge disks, many partitions) |
| Boot code location | First 512 bytes of disk (MBR) | `.efi` file on a FAT32 ESP |
| Secure Boot support | No | Yes |
| Boot speed / features | Slower, 16-bit real mode init | Faster, supports network boot, larger drivers |
| What you'll encounter | Older physical servers, some legacy VMs | Virtually all new hardware and cloud VM images since ~2015+ |

**Bottom line: you don't get to choose this per-boot — it's determined by firmware/hardware and how the disk was partitioned at install time. What you DO need to know: check `[ -d /sys/firmware/efi ]` to tell which mode a running system booted in, since GRUB reinstalls, dual-boot repairs, and disk-cloning procedures differ completely between the two.**

## Hands-On Examples

**1. Determine whether the running system booted via BIOS or UEFI**
```bash
$ [ -d /sys/firmware/efi ] && echo "UEFI boot" || echo "BIOS (legacy) boot"
UEFI boot

$ efibootmgr -v
BootCurrent: 0001
BootOrder: 0001,0000
Boot0000* Windows Boot Manager
Boot0001* ubuntu    HD(1,GPT,3a1e...,0x800,0x100000)/File(\EFI\ubuntu\shimx64.efi)
```

**2. Inspecting GRUB configuration**
```bash
$ cat /etc/default/grub | grep -v "^#"
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""

$ ls /boot/grub/
grub.cfg  grubenv  fonts/  locale/  x86_64-efi/

# Regenerate grub.cfg after changing /etc/default/grub (Ubuntu/Debian)
$ sudo update-grub
Sourcing file `/etc/default/grub'
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-5.15.0-91-generic
Found initrd image: /boot/initrd.img-5.15.0-91-generic
done
```
```bash
# RHEL/Rocky/Fedora equivalent
$ sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

**3. Checking what PID 1 actually is, and confirming systemd**
```bash
$ ps -p 1 -o pid,comm
    PID COMMAND
      1 systemd

$ systemctl --version
systemd 249 (249.11-0ubuntu3.12)
```

**4. Viewing the current boot target (replaces old "runlevel")**
```bash
$ systemctl get-default
graphical.target

$ systemctl list-units --type=target
UNIT                   LOAD   ACTIVE SUB    DESCRIPTION
basic.target           loaded active active Basic System
cryptsetup.target      loaded active active Local Encrypted Volumes
multi-user.target      loaded active active Multi-User System
network.target         loaded active active Network
sysinit.target         loaded active active System Initialization
```

**5. Reading boot-time logs with `journalctl` — the real-world debugging entry point**
```bash
$ journalctl -b -p err
Aug 08 09:00:12 platform-01 kernel: nvme nvme0: I/O 45 timeout
Aug 08 09:00:41 platform-01 systemd[1]: Failed to start Network Manager.

$ systemd-analyze
Startup finished in 3.912s (kernel) + 8.104s (userspace) = 12.016s
graphical.target reached after 8.041s in userspace

$ systemd-analyze blame | head -5
5.201s NetworkManager-wait-online.service
2.104s snapd.service
1.883s systemd-udev-settle.service
0.912s docker.service
```
`systemd-analyze blame` is a standard real-world tool for "why does this box take 45 seconds to boot" investigations — attributing boot-time to specific slow services.

**6. Real scenario: a server stuck at boot after a kernel/initramfs mismatch**
```bash
$ ls /boot/
config-5.15.0-91-generic  initrd.img-5.15.0-91-generic  vmlinuz-5.15.0-91-generic
config-5.15.0-88-generic  vmlinuz-5.15.0-88-generic
# ^ notice: no initrd.img for -88-generic — it was deleted manually, breaking that boot entry

$ sudo update-initramfs -c -k 5.15.0-88-generic
Generating /boot/initrd.img-5.15.0-88-generic
```
A missing initramfs for a given kernel version is a genuine, real "won't boot / drops to emergency shell" cause — this is exactly the kind of concrete, verifiable failure mode senior candidates should be able to name, not just recite the boot chain abstractly.

**7. Booting into rescue/emergency mode conceptually (GRUB kernel parameter edit)**
```bash
# At the GRUB menu, press 'e' to edit, find the line starting with 'linux', append:
linux /vmlinuz-5.15.0-91-generic root=UUID=... ro quiet splash systemd.unit=rescue.target
# Ctrl+X or F10 to boot with that one-time edit
```
Appending `systemd.unit=rescue.target` (or `single`/`1` on older systems) at the GRUB kernel line is the standard "I need a root shell to fix something, and normal boot isn't working" recovery technique — worth knowing hands-on, not just in theory.

## Practice Questions

1. Walk through the full boot sequence from power-on to login prompt, naming every stage in order.
2. What's the practical difference between BIOS and UEFI in terms of partition tables and boot code storage location?
3. What is the initramfs, why does the kernel need it before mounting the real root filesystem, and what happens to it once the real root is mounted?
4. A server won't boot and drops into an "emergency mode" shell. What are the first two or three things you'd check, based on knowing the boot chain?
5. What is PID 1, and why does it matter that it's specifically `systemd` (versus some other process) on most modern distros?
6. Explain the relationship between systemd "targets" and the old SysV "runlevels" — give one concrete mapping (e.g., which target ≈ runlevel 3).
7. How would you determine, without rebooting, whether a running Linux system booted via BIOS or UEFI?
8. You need to regenerate GRUB's configuration after editing `/etc/default/grub`. What command do you run on Ubuntu, and what's the equivalent on RHEL/Rocky?
9. A kernel upgrade leaves an inconsistent state — the new kernel entry appears in GRUB but the system fails to boot into it, while the previous kernel version still boots fine. What's a likely root cause, and how would you investigate/fix it?
10. How would you boot a system into a single-user/rescue shell when normal boot is failing, and why is this useful for recovery scenarios (e.g., resetting a forgotten root password)?

## Interview Key Points

- **Know the exact stage order cold**: firmware (BIOS/UEFI) → bootloader (GRUB) → kernel + initramfs → real root mount → PID 1 (systemd) → targets/services → login. This sequence question is asked constantly and candidates frequently garble the order (especially where initramfs fits).
- **PID 1 matters** — it's the only process the kernel starts directly; everything else is a descendant of it. Recognizing `systemd` as PID 1 via `ps -p 1` is a quick, concrete way to demonstrate hands-on familiarity.
- **initramfs vs real root** is a frequently misunderstood distinction — the initramfs is a temporary, minimal, memory-resident filesystem whose only job is finding and mounting the real one (critical when root is on LVM, RAID, encrypted, or needs a driver not built into the kernel).
- **systemd targets replace SysV runlevels conceptually** but aren't a strict 1:1 mapping — know `multi-user.target` ≈ runlevel 3 (no GUI) and `graphical.target` ≈ runlevel 5 (with GUI) as the most commonly asked pairing.
- `systemd-analyze` and `systemd-analyze blame` are the real tools used to diagnose slow boots in production — naming these unprompted signals hands-on experience over textbook knowledge.
- GRUB config is **generated**, never hand-edited directly (`grub.cfg` is regenerated via `update-grub` on Debian/Ubuntu or `grub2-mkconfig` on RHEL family) — editing `grub.cfg` directly and having it overwritten on the next kernel update is a classic beginner mistake to flag.
- Appending `systemd.unit=rescue.target` (or legacy `single`) at the GRUB kernel command line for one-time recovery boots is genuinely useful, real, hands-on knowledge (e.g., resetting a lost root password) — a strong practical answer if asked about recovery scenarios.
- UEFI Secure Boot (signature-verified boot chain) is worth mentioning as the modern security layer BIOS never had — relevant when discussing why some custom/out-of-tree kernel modules fail to load on Secure-Boot-enabled systems.

Sources:
- [21 Days of DevOps Interview — Day 10 — Linux Boot Process](https://devopslearning.medium.com/21-days-of-devops-interview-day-10-linux-boot-process-09cb3d145803)
- [The Linux Boot Process: An INTERVIEW favourite](https://blog.coderco.io/p/the-linux-boot-process-an-interview)
- [Understanding the Linux Boot Process: UEFI, GRUB, Kernel, initramfs, and systemd Explained](https://eeengineer.com/en/linux-boot-process-uefi-grub-kernel-systemd/)
- [Linux Boot Process Step By Step And Interview Questions](https://onlinetutorialhub.com/linux/linux-boot-process-step-by-step/)
