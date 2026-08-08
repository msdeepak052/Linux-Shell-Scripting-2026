# Linux Capabilities vs Full Root (`setcap`, `getcap`)

Capabilities split root's monolithic superpower into ~40 discrete permissions, letting a binary do exactly one privileged thing (like bind to port 80) without being fully root — a core building block of least-privilege hardening.

## Explanation

**The problem capabilities solve**: traditionally, a process is either root (UID 0, can do *anything*) or a normal user (can do almost nothing privileged). Binding to a port below 1024, for example, historically required full root via `setuid root`. If that binary has a bug, the attacker gets full root — way more than the binary ever needed.

**Capabilities** (Linux kernel feature, `man 7 capabilities`) break root's power into individual named units. A process/binary can be granted just the one it needs:
- `CAP_NET_BIND_SERVICE` — bind to ports < 1024 without being root.
- `CAP_NET_RAW` — use raw sockets (e.g., `ping`, packet sniffers).
- `CAP_SYS_ADMIN` — the infamous "basically root" catch-all capability (mount, namespaces, etc.) — a red flag if seen granted broadly.
- `CAP_CHOWN` — change file ownership without being root.
- `CAP_DAC_OVERRIDE` — bypass file read/write/execute permission checks.
- `CAP_SETUID` / `CAP_SETGID` — change process UID/GID.
- `CAP_KILL` — send signals to processes owned by other users.
- `CAP_SYS_PTRACE` — trace/debug other processes (`strace`, `gdb` on others' processes).

**Capability sets** (per-process, in `/proc/<pid>/status`): `CapInh` (inheritable), `CapPrm` (permitted), `CapEff` (effective — what's actually checked), `CapBnd` (bounding — ceiling that can ever be gained), `CapAmb` (ambient — since Linux 4.3, preserved across `execve` for non-SUID programs).

**File capabilities** (`setcap`) attach capabilities directly to a binary's extended attributes (`security.capability` xattr) — the kernel grants that capability to the process when the binary runs, no `setuid` bit needed:
```bash
sudo setcap cap_net_bind_service=+ep /usr/bin/node
```
- `+ep` = add to Effective and Permitted sets.
- `+eip` = also add Inheritable (needed for the capability to survive certain `exec` chains).

**`getcap`** reads back what's set:
```bash
getcap /usr/bin/node
getcap -r /usr/bin    # recursive scan of a directory
```

**Why capabilities beat `setuid root` / running as root**:
- Blast radius: a compromised `CAP_NET_BIND_SERVICE`-only process can bind privileged ports but can't read `/etc/shadow`, kill arbitrary processes, or load kernel modules.
- Auditable: `getcap -r /` gives a clear inventory of every binary with elevated power on a system — much harder to audit "is this setuid-root binary safe" case by case.
- Composable with containers: Docker/Kubernetes let you `--cap-drop=ALL --cap-add=NET_BIND_SERVICE` instead of `--privileged`, dramatically shrinking a container's attack surface.

**Gotchas**:
- Capabilities attached via `setcap` are **lost on file copy** (xattrs often don't survive `cp` without `--preserve=xattr`, and never survive tar/rsync without explicit flags, or being re-extracted from an image layer) — a common "why did my capability disappear after deployment" bug.
- **`CAP_SYS_ADMIN` is "the new root"** — so broad (mount filesystems, arbitrary ioctls, namespace manipulation) that granting it is nearly equivalent to full root; interviewers use this to test if you understand capabilities aren't automatically "safe."
- File capabilities **don't work reliably on scripts** (shebang interpreted files) — the capability check happens on the ELF binary being exec'd; for a script, that's `/bin/bash`, which would then have the capability for *every* script it runs. Use a small compiled wrapper or systemd `AmbientCapabilities=` instead.
- **NFS and some filesystems don't support xattrs**, so `setcap` silently fails or doesn't persist there.
- Capabilities interact with **bounding set** — even if a process has a capability in `CapPrm`, if it's not in `CapBnd`, it can never be effective; container runtimes often shrink the bounding set.
- Environment variable `PR_SET_NO_NEW_PRIVS` (used by systemd's `NoNewPrivileges=`) can prevent file capabilities from taking effect at all — another common "why doesn't my setcap binary work under systemd" trap.

## Hands-On Examples

**1. The classic use case — letting a non-root process bind port 80**
```bash
$ whoami
appuser
$ ./myserver --port 80
Error: listen EACCES: permission denied 0.0.0.0:80

$ sudo setcap cap_net_bind_service=+ep /usr/local/bin/myserver
$ getcap /usr/local/bin/myserver
/usr/local/bin/myserver cap_net_bind_service=ep

$ ./myserver --port 80
Server listening on 0.0.0.0:80
$ ps -o user,pid,cmd -C myserver
USER     PID CMD
appuser 4821 ./myserver --port 80
```
Process runs as `appuser`, not root, but can still bind port 80.

**2. Comparing to the old `setuid root` approach**
```bash
$ ls -la /usr/bin/ping
-rwsr-xr-x 1 root root 64424 Mar  1 09:00 /usr/bin/ping
```
`ping` traditionally needed `setuid root` (the `s` bit) for raw sockets — full root during execution, even though it only ever needs `CAP_NET_RAW`. Modern distros fix this with capabilities instead:
```bash
$ getcap /usr/bin/ping
/usr/bin/ping cap_net_raw=ep
$ ls -la /usr/bin/ping
-rwxr-xr-x 1 root root 64424 Mar  1 09:00 /usr/bin/ping   # no setuid bit needed
```

**3. Auditing a whole system for privileged binaries**
```bash
$ sudo getcap -r / 2>/dev/null
/usr/bin/ping cap_net_raw=ep
/usr/bin/mtr-packet cap_net_raw=ep
/usr/bin/traceroute6.iputils cap_net_raw=ep
/usr/local/bin/myserver cap_net_bind_service=ep

$ find / -perm -4000 -type f 2>/dev/null   # compare: remaining setuid-root binaries
/usr/bin/sudo
/usr/bin/passwd
/usr/bin/su
```
A security audit typically runs both — full inventory of "who has elevated power and how."

**4. Removing a capability**
```bash
$ sudo setcap -r /usr/local/bin/myserver
$ getcap /usr/local/bin/myserver
$ ./myserver --port 80
Error: listen EACCES: permission denied 0.0.0.0:80
```

**5. Capabilities silently lost on copy/deploy — a real production bug**
```bash
$ sudo setcap cap_net_bind_service=+ep /usr/local/bin/myserver
$ cp /usr/local/bin/myserver /opt/releases/myserver-v2
$ getcap /opt/releases/myserver-v2
                                    # empty — capability did NOT survive the copy

$ cp --preserve=xattr /usr/local/bin/myserver /opt/releases/myserver-v3
$ getcap /opt/releases/myserver-v3
/opt/releases/myserver-v3 cap_net_bind_service=ep
```
This is why CI/CD pipelines that build a binary, then `docker cp` or `rsync` it into an image, often need an explicit `RUN setcap ...` step baked into the Dockerfile rather than relying on the capability surviving the copy.

**6. Docker: capabilities instead of `--privileged`**
```bash
$ docker run --rm --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
    -p 80:80 myapp:latest
```
```bash
$ docker inspect --format '{{.HostConfig.CapAdd}} / {{.HostConfig.CapDrop}}' mycontainer
[NET_BIND_SERVICE] / [ALL]
```
Compare to `--privileged`, which grants *every* capability plus device access — never appropriate for a service that only needs to bind a low port.

**7. Inspecting a running process's actual capability sets**
```bash
$ pid=$(pgrep myserver)
$ grep -i cap /proc/$pid/status
CapInh: 0000000000000000
CapPrm: 0000000000000400
CapEff: 0000000000000400
CapBnd: 00000001ffffffff
CapAmb: 0000000000000000

$ capsh --decode=0000000000000400
0x0000000000000400=cap_net_bind_service
```
`capsh --decode` translates the hex bitmask into human-readable capability names — useful when auditing `/proc/<pid>/status` directly.

**8. The `CAP_SYS_ADMIN` red flag during a review**
```bash
$ getcap -r /opt/vendor-app
/opt/vendor-app/bin/agent cap_sys_admin,cap_sys_ptrace,cap_net_admin=eip

$ capsh --print | grep Current
Current: = cap_sys_admin,cap_sys_ptrace,cap_net_admin+eip
```
`cap_sys_admin` here is effectively "give this binary root" — an auditor should immediately question why a monitoring "agent" needs mount/namespace-level power, and push for the vendor to justify or narrow it (or containerize + drop caps at the runtime layer instead).

## Practice Questions

1. What specific problem do Linux capabilities solve compared to the traditional "root or nothing" model, and what capability replaces the need for `ping` to be `setuid root`?
2. Walk through the exact commands to let a Node.js app bind to port 443 without running as root, then verify it worked.
3. What's the difference between `CapPrm`, `CapEff`, and `CapBnd` in `/proc/<pid>/status`, and why can a process have a capability in `CapPrm` but not actually be able to use it?
4. Why is `CAP_SYS_ADMIN` considered "almost as dangerous as full root," and what should you do if you find a production binary granted it?
5. A team copies a `setcap`-configured binary into a new Docker image with a plain `COPY` instruction, and the capability disappears at runtime. Explain why, and give two ways to fix the deployment pipeline.
6. Why doesn't `setcap` reliably work on a shell script (e.g., a Python script with a `#!/usr/bin/env python3` shebang), and what are two alternative approaches to grant it a capability?
7. Compare `docker run --privileged` to `docker run --cap-drop=ALL --cap-add=NET_BIND_SERVICE` — what's the practical security difference for an attacker who compromises the container?
8. Write the command to audit an entire filesystem for binaries carrying file capabilities, and explain why this audit should be run alongside a `find / -perm -4000` setuid audit rather than instead of it.
9. What is `systemd`'s `AmbientCapabilities=` directive used for, and how does it relate to running a non-setuid binary with a specific capability under a systemd unit?
10. `NoNewPrivileges=true` is set on a systemd unit, and a `setcap`-granted capability on the unit's binary stops working. Explain why.

## Interview Key Points

- **Capabilities exist to avoid "all or nothing" root** — always frame the answer as least-privilege: grant exactly the one capability a binary needs (e.g., `cap_net_bind_service` for a port-80 web server) instead of `setuid root` or running the whole process as root.
- Know the concrete example cold: **`setcap cap_net_bind_service=+ep /path/to/binary`** lets a non-root process bind ports < 1024 — this is the single most commonly asked hands-on capabilities question.
- **`CAP_SYS_ADMIN` is "the new root"** — interviewers use it to check whether you understand that capabilities aren't inherently safe; a binary with `cap_sys_admin` is a near-full-root compromise if exploited.
- **File capabilities don't survive naive copies** (`cp` without `--preserve=xattr`, tar/rsync without xattr flags, most Docker `COPY` from build stage to build stage in some configurations) — a real deployment gotcha worth mentioning proactively.
- Distinguish the **four capability sets** — Effective (checked now), Permitted (can be raised to Effective), Inheritable (passed across exec), Bounding (hard ceiling) — at least at a conceptual level; `CapBnd` limiting what's ever attainable is the nuance that separates strong answers.
- Capabilities **don't attach cleanly to interpreted scripts** — the kernel checks the xattr on the ELF being exec'd, which for a script is the interpreter, not the script; systemd's `AmbientCapabilities=` or a compiled wrapper are the real answers.
- In container contexts, **`--cap-drop=ALL --cap-add=<specific>` is the modern replacement for `--privileged`** — expect to be asked to justify why `--privileged` is dangerous and how capabilities narrow that.
- `getcap -r /` for an audit inventory, `setcap -r` to strip a capability, `capsh --decode=<hex>` to translate `/proc/<pid>/status` bitmasks into names — know these three commands by heart.
