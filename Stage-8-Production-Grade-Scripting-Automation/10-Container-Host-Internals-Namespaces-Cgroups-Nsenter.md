# Container-Host Internals: Namespaces, Cgroups, `nsenter`

Containers are not VMs — they're regular Linux processes isolated by namespaces and constrained by cgroups. Understanding this is what separates "I run `kubectl exec`" from "I can debug a container problem when `kubectl exec` itself doesn't work."

## Explanation

**Namespaces** — kernel feature that isolates what a process *can see*. Each container gets its own namespace instances for:
- `pid` — process IDs; inside the container, the main process is PID 1, but it has a different PID visible from the host.
- `net` — network interfaces, routing tables, ports; a container's `localhost` is isolated from the host's.
- `mnt` — mount points; the container's filesystem view (its "root") is isolated via `mnt` + typically `chroot`/`pivot_root`.
- `uts` — hostname/domainname isolation.
- `ipc` — System V IPC/message queues isolation.
- `user` — UID/GID mapping, lets "root" inside a container map to an unprivileged UID on the host (rootless containers).
- `cgroup` — isolates the view of the cgroup hierarchy itself.

A container is, from the host's point of view, just a process with a distinct set of namespace IDs — visible via `ls -la /proc/<pid>/ns/`.

**Cgroups (control groups)** — kernel feature that *limits and accounts for* resource usage (CPU, memory, I/O, PIDs) per process group, independent of namespaces (isolation and limiting are separate concerns). Container runtimes create a cgroup per container and set limits matching `--memory`/`--cpus`/Kubernetes resource requests/limits.
- cgroup v1: separate hierarchies per controller, under `/sys/fs/cgroup/memory/`, `/sys/fs/cgroup/cpu/`, etc.
- cgroup v2 (unified hierarchy, default on modern distros/kernels): single tree under `/sys/fs/cgroup/`, controllers listed in `cgroup.controllers`.
- Key files (v2): `memory.max` (hard limit), `memory.current` (usage now), `cpu.max` (quota/period), `pids.max`.
- When a container hits its `memory.max`, the kernel's OOM killer fires **scoped to that cgroup** — it kills a process inside the container without necessarily affecting the host or other containers.

**`nsenter`** — enters one or more of another process's namespaces. This is the tool you reach for when a container has no shell, `docker exec`/`kubectl exec` isn't available, or you need host-level tools (like `tcpdump`, unavailable in a minimal image) applied to a container's network namespace.
```bash
nsenter -t <PID> -n -p -- <command>    # -n = net namespace, -p = pid namespace
```
- `-t <PID>` — target PID (find it via `docker inspect --format '{{.State.Pid}}'` or `crictl inspect`).
- Flags select which namespaces to join: `-n` net, `-p` pid, `-m` mnt, `-u` uts, `-i` ipc, `-U` user. Combine as needed.
- Classic use case: `nsenter -t <pid> -n -- tcpdump -i eth0` — run the **host's** `tcpdump` binary but inside the container's network namespace, without needing `tcpdump` installed in the container image at all.

**Why this matters operationally**: it's the escape hatch when the higher-level tooling (`kubectl exec`, `docker exec`) fails or isn't rich enough — e.g., debugging network issues in a container with no debug tools, or when a container's shell itself is hung/corrupted but its process is still alive and inspectable from the host.

## Hands-On Examples

**1. Listing a container's namespaces from the host**
```bash
$ docker inspect --format '{{.State.Pid}}' web-01
48213
$ sudo ls -la /proc/48213/ns/
lrwxrwxrwx 1 root root 0 net -> 'net:[4026532341]'
lrwxrwxrwx 1 root root 0 pid -> 'pid:[4026532342]'
lrwxrwxrwx 1 root root 0 mnt -> 'mnt:[4026532339]'
lrwxrwxrwx 1 root root 0 uts -> 'uts:[4026532340]'
```

**2. `nsenter` to get a shell in a container with none installed**
```bash
$ docker inspect --format '{{.State.Pid}}' minimal-app
51022
$ sudo nsenter -t 51022 -n -p -m -u -i sh
# now inside the container's mount/pid/net namespaces, using the HOST's sh binary
/ # ls /
/ # ps aux    # sees only processes in this pid namespace
```

**3. Running host `tcpdump` inside a container's network namespace (image has no tcpdump)**
```bash
$ pid=$(docker inspect --format '{{.State.Pid}}' payments-api)
$ sudo nsenter -t "$pid" -n -- tcpdump -i eth0 -c 20 port 5432
tcpdump: listening on eth0
10:14:02.881221 IP payments-api.41022 > db.postgres: Flags [S], seq 123...
10:14:02.881980 IP db.postgres > payments-api.41022: Flags [S.], seq 456...
```

**4. Checking a container's memory cgroup limit and current usage directly (cgroup v2)**
```bash
$ pid=$(docker inspect --format '{{.State.Pid}}' payments-api)
$ cgroup_path=$(cat /proc/$pid/cgroup | grep '^0::' | cut -d: -f3)
$ cat /sys/fs/cgroup${cgroup_path}/memory.max
536870912
$ cat /sys/fs/cgroup${cgroup_path}/memory.current
534200320
```
Usage (534MB) is right against the limit (512MB) — this container is a strong OOM-kill candidate.

**5. Confirming a container was cgroup-OOM-killed vs host-level OOM**
```bash
$ dmesg -T | grep -i "killed process" | tail -3
[Thu Aug  8 10:15:44 2026] Killed process 51022 (node) total-vm:1240192kB, anon-rss:524288kB, ...

$ dmesg -T | grep -B5 "Killed process 51022" | grep -i cgroup
[Thu Aug  8 10:15:44 2026] Task in /kubepods/burstable/pod.../containerXYZ killed as a result of limit of that cgroup
```
The "Task in ... killed as a result of limit of that cgroup" line confirms it was the **container's** memory limit, not host-wide memory pressure.

**6. Comparing PID namespace views: host vs inside container**
```bash
$ ps aux | grep node | head -1
root     48213  0.3  1.2 ... node server.js       # host PID 48213

$ docker exec web-01 ps aux
PID   USER  COMMAND
1     root  node server.js                        # same process, PID 1 inside its namespace
```

**7. Checking CPU throttling via cgroup v2 stats — diagnosing "app is slow but CPU% looks fine"**
```bash
$ cgroup_path=$(cat /proc/$pid/cgroup | grep '^0::' | cut -d: -f3)
$ cat /sys/fs/cgroup${cgroup_path}/cpu.stat
usage_usec 48291823
nr_periods 91234
nr_throttled 8821
throttled_usec 15029442
```
`nr_throttled` (8821 of 91234 periods throttled) confirms the container is regularly hitting its CPU quota — classic cause of latency spikes that don't show as high CPU% in coarse-grained monitoring.

**8. Using `nsenter` when `docker exec`/`kubectl exec` themselves are broken (dockerd hung)**
```bash
# dockerd is unresponsive, docker exec hangs; find the PID via the containerd/CRI shim instead
$ sudo crictl inspect <container-id> | jq '.info.pid'
51022
$ sudo nsenter -t 51022 -a sh    # -a = enter ALL available namespaces
/ # cat /proc/1/status | grep State
```

## Practice Questions

1. Explain the difference between what namespaces provide (isolation) versus what cgroups provide (resource limiting/accounting). Why are they separate kernel mechanisms rather than one feature?
2. A container's PID 1 process shows as PID 48213 on the host but PID 1 inside `docker exec`. Explain why, referencing the PID namespace mechanism specifically.
3. Write the `nsenter` command to run the host's `tcpdump` against a container's network interface, given you've found its PID via `docker inspect`. Why is this preferable to installing `tcpdump` inside the container image?
4. Given a container's cgroup path, how do you find its current memory usage versus its hard limit (cgroup v2)? What file holds each value?
5. `dmesg` shows "Killed process 51022" — what additional line in the surrounding `dmesg` output would confirm this was a cgroup-scoped OOM kill (container limit) rather than host-wide memory exhaustion?
6. An application's CPU usage graph looks moderate, but users report intermittent latency spikes. What cgroup v2 file/metric would you check to see if the container is being CPU-throttled, and what field specifically indicates throttling occurred?
7. `docker exec` and `kubectl exec` both hang or fail because the container runtime daemon itself is unresponsive. Describe an alternative path to get a shell/diagnostics into the affected container's namespaces.
8. What's the difference between cgroup v1 and cgroup v2 in terms of directory/hierarchy structure? Why does this matter when writing a script that reads cgroup limits directly from `/sys/fs/cgroup`?
9. What does `-U` (user namespace) provide in the context of rootless containers, and why might "root" inside a container map to a non-root, unprivileged UID on the host?
10. Given only a container's PID, walk through how you'd inspect: (a) its namespace IDs, (b) its cgroup memory limit, (c) its network interfaces — without using `docker`/`kubectl` at all, purely via `/proc` and `/sys`.

## Interview Key Points

- Namespaces isolate *visibility* (what a process can see: PIDs, network, mounts); cgroups constrain *consumption* (CPU, memory, I/O, PID count) — conflating the two is a common junior mistake worth explicitly correcting in an answer.
- `nsenter` is the escape hatch for debugging when higher-level tools (`docker exec`, `kubectl exec`) are unavailable, hung, or the target image lacks the needed debug tools entirely — know the flag meanings (`-t` target PID, `-n`/`-p`/`-m`/`-u`/`-i`/`-U` per-namespace, `-a` for all).
- Running the **host's** debugging binaries (`tcpdump`, `strace`) inside a container's namespace via `nsenter` is a signature senior move — it solves "minimal/distroless image has no tools" without rebuilding the image.
- OOM kills are cgroup-scoped under Kubernetes/Docker — always confirm via `dmesg`'s "killed as a result of limit of that cgroup" line whether it was a container-level limit versus true host-wide memory pressure; these require different remediation (raise container limit vs. add node capacity).
- `cpu.stat`'s `nr_throttled`/`throttled_usec` (cgroup v2) is the specific, non-obvious answer to "app is slow, CPU% graphs look fine" — CFS quota throttling doesn't always show up as sustained high CPU%, only as periodic stalls.
- Know cgroup v1 (per-controller hierarchies) vs v2 (single unified hierarchy) exists and that file paths/structure differ — scripts reading `/sys/fs/cgroup` directly must account for which version the host runs (`cat /sys/fs/cgroup/cgroup.controllers` existing implies v2).
- A container is fundamentally a regular host process with distinct namespace IDs — `ps aux` on the host shows every containerized process too; this framing (no "magic," just namespaces + cgroups + normal processes) is what interviewers want to hear to confirm real understanding versus tool-only familiarity.
