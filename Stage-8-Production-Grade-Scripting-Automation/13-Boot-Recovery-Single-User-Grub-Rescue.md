# Boot & Recovery: Single-User/Rescue Mode, GRUB Recovery

A box that won't boot is the highest-stakes shell-adjacent skill in the whole stage — no SSH, no logs shipped anywhere, just a console and boot-time tooling standing between you and an outage.

## Explanation

**Boot sequence recap** (needed to know where to intervene): firmware (BIOS/UEFI) -> bootloader (GRUB) -> kernel + initramfs -> `init`/systemd (PID 1) -> targets/runlevels -> login.

**GRUB recovery/editing at boot**:
- At the GRUB menu, press `e` on a boot entry to edit it for **this boot only** (not persisted) — used to append kernel parameters.
- Append `single` or `1` to the `linux`/`linuxefi` line to boot directly into **single-user/rescue mode** (minimal services, root shell, no full multi-user target) — used when a broken service or full boot process itself is the problem.
- Append `init=/bin/bash` (or `init=/bin/sh`) to skip `init`/systemd entirely and get a raw root shell as PID 1 — the nuclear option when even single-user target won't start (used for e.g. fixing a corrupted `/etc/fstab` or resetting a lost root password).
- `Ctrl+X` or `F10` to boot with the edited line; changes are NOT saved to disk (edit again next reboot if needed) — to persist, edit `/etc/default/grub` + `update-grub`/`grub2-mkconfig` from a working boot.

**Systemd rescue vs emergency targets** (modern equivalent of old SysV runlevels 1/S):
- `systemctl rescue` (or boot with `systemd.unit=rescue.target`) — mounts local filesystems, single-user shell, most services NOT started.
- `systemctl emergency` (`systemd.unit=emergency.target`) — even more minimal: root filesystem mounted **read-only**, almost nothing started — used when rescue.target itself can't come up (e.g., a broken fstab preventing normal mounts).
- In emergency mode, `mount -o remount,rw /` is usually the first command needed before you can edit anything.

**GRUB itself broken/missing** (`grub rescue>` prompt, or no bootloader menu at all):
- Boot from a live USB/rescue ISO, `mount` the broken system's root + boot partitions, `chroot` into it, then reinstall GRUB (`grub-install /dev/sda` + `update-grub`/`grub2-mkconfig -o /boot/grub2/grub.cfg`).
- `chroot` requires bind-mounting `/dev`, `/proc`, `/sys` from the live environment into the chroot first, or tools like `grub-install` won't work correctly inside it.

**Common "won't boot" root causes and their fixes**:
- Corrupted/misconfigured `/etc/fstab` (e.g., a bad UUID or missing device) — drops to emergency shell; fix the file, `mount -a` to verify, reboot.
- Full root filesystem preventing services/journal from starting — boot rescue/single-user, free space, reboot.
- Bad kernel/initramfs after an update — select the previous kernel entry from the GRUB menu (this is exactly why old kernel entries are kept around).
- Lost root password — `init=/bin/bash` -> remount rw -> `passwd root` -> reboot.
- LUKS/encrypted root asking for a passphrase that's lost/wrong — separate, harder problem; requires the recovery key, not a shell trick.

## Hands-On Examples

**1. Booting into single-user mode by editing the GRUB entry live**
```text
# At GRUB menu, highlight the entry, press 'e'
linux   /boot/vmlinuz-5.15.0-105-generic root=UUID=xxxx ro quiet splash
# Change 'ro quiet splash' to add 'single' at the end:
linux   /boot/vmlinuz-5.15.0-105-generic root=UUID=xxxx ro single
# Press Ctrl+X to boot with this edit (one-time only)
```
```bash
# You land at a root shell, no login prompt needed
root@host:~# systemctl status nginx
```

**2. `init=/bin/bash` — the nuclear option to reset a lost root password**
```text
# In GRUB edit mode, append to the linux line:
linux   /boot/vmlinuz-5.15.0-105-generic root=UUID=xxxx init=/bin/bash
```
```bash
# Filesystem is mounted read-only at this point — remount rw first
bash-5.1# mount -o remount,rw /
bash-5.1# passwd root
New password: ********
Retype new password: ********
passwd: password updated successfully
bash-5.1# exec /sbin/init    # or just reboot -f
```

**3. Systemd rescue vs emergency target, chosen via kernel parameter**
```text
linux   /boot/vmlinuz-5.15.0-105-generic root=UUID=xxxx systemd.unit=rescue.target
```
```text
linux   /boot/vmlinuz-5.15.0-105-generic root=UUID=xxxx systemd.unit=emergency.target
```
```bash
# In emergency.target, root is typically read-only — this is nearly always your first command
emergency# mount -o remount,rw /
```

**4. Fixing a bad `/etc/fstab` that's blocking normal boot**
```bash
# Dropped to emergency shell with message:
# "A start job is running for /dev/disk/by-uuid/... (fstab entry)"
emergency# mount -o remount,rw /
emergency# cat /etc/fstab
UUID=1234-5678  /data  ext4  defaults  0 2     # this device no longer exists

emergency# vi /etc/fstab     # comment out or fix the offending line
emergency# mount -a          # verify the fix works before rebooting
emergency# systemctl default # or just: reboot
```

**5. Booting the previous kernel after a bad kernel update**
```text
# GRUB menu -> "Advanced options for Ubuntu" -> select the PREVIOUS kernel version
# (this is why distros keep old kernel entries around after updates)
```
```bash
$ uname -r
5.15.0-102-generic     # confirms we're on the older, working kernel
$ apt remove --purge linux-image-5.15.0-105-generic   # remove the bad one once booted
```

**6. GRUB itself is broken — reinstalling from a live/rescue ISO via `chroot`**
```bash
# Booted from a live USB/rescue ISO
live# lsblk
NAME   SIZE FSTYPE  MOUNTPOINT
sda1   512M vfat
sda2   50G  ext4

live# mount /dev/sda2 /mnt
live# mount /dev/sda1 /mnt/boot/efi     # if UEFI with a separate ESP
live# for d in dev proc sys; do mount --bind /$d /mnt/$d; done
live# chroot /mnt /bin/bash

chroot# grub-install /dev/sda
chroot# update-grub
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-5.15.0-105-generic
done

chroot# exit
live# umount -R /mnt
live# reboot
```

**7. Diagnosing a full root filesystem preventing boot completion**
```bash
# Dropped to emergency shell, systemd-journald failing to start
emergency# mount -o remount,rw /
emergency# df -h /
Filesystem  Size  Used Avail Use% Mounted on
/dev/sda2    20G   20G     0 100% /

emergency# du -sh /var/log/* | sort -rh | head -5
8.2G  /var/log/journal
6.1G  /var/log/app/app.log

emergency# truncate -s 0 /var/log/app/app.log
emergency# journalctl --vacuum-size=200M
emergency# reboot
```

**8. Persisting a GRUB kernel-parameter change (not just a one-time edit)**
```bash
$ sudo vi /etc/default/grub
# Edit: GRUB_CMDLINE_LINUX_DEFAULT="quiet splash systemd.unit=rescue.target"
# (Example only — you'd normally NOT want rescue.target permanent; more realistic: adding cgroup or IOMMU params)

$ sudo update-grub                          # Debian/Ubuntu
$ sudo grub2-mkconfig -o /boot/grub2/grub.cfg   # RHEL/CentOS/Fedora
```

## Practice Questions

1. Walk through the exact GRUB-menu steps to boot a system into single-user mode to fix a broken service, without permanently changing the boot configuration.
2. What's the difference between appending `single` versus `init=/bin/bash` to a kernel's boot line? When would you need the more drastic `init=/bin/bash` option?
3. You reset a lost root password via `init=/bin/bash`, but `passwd root` fails with "Read-only file system." What's the missing step, and why is the filesystem read-only at that point?
4. Explain the difference between systemd's `rescue.target` and `emergency.target`. Give a scenario where `rescue.target` itself would fail to come up, forcing you to use `emergency.target` instead.
5. A server won't boot after a kernel update — it hangs/panics early in boot. What's the fastest recovery path that doesn't require a rescue ISO at all?
6. The GRUB bootloader itself is corrupted/missing (`grub rescue>` prompt). Outline the full recovery procedure using a live/rescue ISO, including why you need to bind-mount `/dev`, `/proc`, `/sys` before `chroot`.
7. A box drops to an emergency shell on boot with a message about a `start job running for /dev/disk/by-uuid/...`. What's the most likely root cause, and what file do you check/fix?
8. Why does editing a boot entry at the GRUB menu (pressing `e`, then `Ctrl+X`) NOT persist across reboots, and what do you edit instead to make a kernel parameter change permanent?
9. A production disk fills up (`/` at 100%) and the box won't finish booting because journald/services can't start. Describe your recovery steps from the emergency shell.
10. Why is a lost LUKS/disk-encryption passphrase a fundamentally different (and much harder) recovery problem than a lost root password? What's the only real fix?

## Interview Key Points

- Know the escalation ladder precisely: normal boot -> `single`/rescue.target (broken service) -> `emergency.target` (broken fstab/mounts) -> `init=/bin/bash` (broken init entirely) -> live/rescue ISO + `chroot` (broken bootloader/filesystem) — interviewers often probe "what would you try first" to gauge whether you escalate sensibly rather than jumping straight to the nuclear option.
- `mount -o remount,rw /` is almost always the first command needed in emergency mode or after `init=/bin/bash` — forgetting this and being confused by "read-only file system" errors is a common stumble worth pre-empting.
- GRUB menu edits (`e` then `Ctrl+X`) are one-boot-only and never persist — persisting requires editing `/etc/default/grub` and regenerating the config (`update-grub` on Debian/Ubuntu, `grub2-mkconfig` on RHEL family). Know both commands by name.
- `chroot` into a broken system from a live ISO requires bind-mounting `/dev`, `/proc`, `/sys` first — omitting this is why "I chrooted but grub-install failed" is a common real-world stumble, and a good interview detail to volunteer.
- Old kernel entries in the GRUB menu exist specifically as a rollback path after a bad kernel update — booting the previous entry is almost always faster than any rescue-ISO workflow, and should be the first thing tried after a kernel-update-induced boot failure.
- A corrupted/stale `/etc/fstab` is one of the single most common real-world causes of a boot hang/emergency-shell drop — know the specific symptom (systemd waiting on a mount unit) and the fix (comment out or correct the bad entry, `mount -a` to verify before rebooting).
- Lost root password (fixable via `init=/bin/bash` + `passwd`) is fundamentally different from a lost LUKS encryption passphrase (not fixable without the recovery key/keyslot backup) — conflating these in an answer is a red flag; know to distinguish them explicitly.
