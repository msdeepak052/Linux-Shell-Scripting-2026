# Container & Kubernetes Debugging from the Shell

When a pod is crash-looping at 2 AM, the difference between resolving it in five minutes and fifty is fluency with `kubectl exec`, `kubectl logs`, `docker exec`, and `crictl` — the tools that let you see inside a running (or just-died) container.

## Explanation

**`docker exec`** — run a command inside a running container's namespace. Requires the container to be running; won't help with a container that already exited/crashed.
- `docker exec -it <container> sh` — interactive shell (use `sh` for minimal/distroless images that lack `bash`).
- `docker logs --tail 100 -f <container>` — recent + follow logs.
- `docker inspect <container>` — full JSON metadata: mounts, env, network, exit code, OOMKilled flag.

**`kubectl exec`** — same idea, one layer up (into a pod's container).
- `kubectl exec -it <pod> -c <container> -- sh` — `-c` required when a pod has multiple containers.
- `kubectl exec` fails outright if the container has already crashed — for that, you need `kubectl logs --previous` or an ephemeral debug container.

**`kubectl logs`**:
- `kubectl logs <pod> -c <container>` — current container's logs.
- `kubectl logs <pod> --previous` (or `-p`) — logs from the **previous** instance of the container, essential for crash-looping pods since the current instance may have just started with no useful log history yet.
- `kubectl logs <pod> --since=10m` / `--tail=200` — bound the output.
- `kubectl logs -l app=payments -f --max-log-requests=10` — tail logs across all pods matching a label selector simultaneously.

**`kubectl describe pod`** — not logs, but often the first stop: shows Events (scheduling failures, image pull errors, OOMKilled, liveness probe failures) that never appear in application logs at all.

**Ephemeral debug containers** (`kubectl debug`) — for distroless/minimal images with no shell at all:
```bash
kubectl debug -it <pod> --image=busybox --target=<container> -- sh
```
Attaches a new container sharing the target's process namespace, letting you inspect processes/filesystem even when the app container has zero debugging tools.

**`crictl`** — the CRI-level tool (works with containerd/CRI-O, i.e., most modern Kubernetes nodes that don't run dockerd) for debugging **at the node**, below what `kubectl` can see — useful when the API server itself is degraded or you're SSH'd onto a node directly.
- `crictl ps -a` — list all containers (including stopped) known to the container runtime on this node.
- `crictl logs <container-id>` — raw runtime-level logs, same data `kubectl logs` gets but accessible even if the kubelet/API server path is broken.
- `crictl inspect <container-id>` — low-level state, exit code, OOM status.
- `crictl pods` — list pod sandboxes at the node/runtime level.

**Key debugging decision tree**: pod won't start -> `describe pod` (Events). Pod crash-looping -> `logs --previous` + `describe pod` (look for OOMKilled/exit code). Pod running but app misbehaving -> `exec` in and inspect directly. Node/kubelet suspected broken -> SSH to node, use `crictl` directly instead of going through `kubectl`.

## Hands-On Examples

**1. `docker exec` into a running container for a quick look**
```bash
$ docker exec -it web-01 sh
/ # ps aux
/ # cat /etc/resolv.conf
/ # exit
```

**2. Finding out WHY a container died — `docker inspect` for OOM/exit code**
```bash
$ docker inspect web-01 --format '{{.State.ExitCode}} OOMKilled={{.State.OOMKilled}}'
137 OOMKilled=true
```
Exit code 137 = 128 + 9 (SIGKILL) — combined with `OOMKilled=true` this confirms the kernel's OOM killer terminated it, not an app crash.

**3. `kubectl exec` with explicit container selection (multi-container pod)**
```bash
$ kubectl get pod payments-api-7d4f9c-xk2q9 -o jsonpath='{.spec.containers[*].name}'
app istio-proxy

$ kubectl exec -it payments-api-7d4f9c-xk2q9 -c app -- sh
/ # curl -s localhost:8080/health
{"status":"ok"}
```

**4. Crash-looping pod — `logs --previous` is the essential move**
```bash
$ kubectl get pods -n payments
NAME                            READY   STATUS             RESTARTS   AGE
payments-api-7d4f9c-xk2q9       0/1     CrashLoopBackOff   6          12m

$ kubectl logs payments-api-7d4f9c-xk2q9 -n payments --previous
Error: could not connect to database: connection refused
FATAL: exiting after 3 failed connection attempts

$ kubectl describe pod payments-api-7d4f9c-xk2q9 -n payments | tail -15
  Warning  BackOff  2m (x30 over 12m)  kubelet  Back-off restarting failed container
```

**5. Tailing logs across all pods behind a label selector**
```bash
$ kubectl logs -l app=payments -n payments -f --max-log-requests=5 --prefix
[pod/payments-api-7d4f9c-xk2q9/app] Handling GET /health
[pod/payments-api-7d4f9c-8b1a2/app] Handling GET /health
[pod/payments-api-7d4f9c-8b1a2/app] ERROR: upstream timeout
```

**6. Ephemeral debug container for a distroless image with no shell**
```bash
$ kubectl exec -it minimal-app-6f9d -- sh
OCI runtime exec failed: exec failed: unable to start container process: exec: "sh": executable file not found in $PATH

$ kubectl debug -it minimal-app-6f9d --image=busybox:1.36 --target=app -n payments -- sh
/ # ls /proc/1/root/app/     # inspect the target container's filesystem via shared process ns
/ # cat /proc/1/environ | tr '\0' '\n'
```

**7. Node-level debugging with `crictl` when `kubectl` access is degraded**
```bash
$ ssh node-03
node-03$ sudo crictl ps -a | grep payments
a1b2c3d4e5f6   payments-api:1.4.2   Exited (137) 3 minutes ago   payments-api

node-03$ sudo crictl inspect a1b2c3d4e5f6 | jq '.status.reason, .status.exitCode'
"OOMKilled"
137

node-03$ sudo crictl logs a1b2c3d4e5f6 | tail -30
```

**8. Correlating pod events with node-level memory pressure**
```bash
$ kubectl describe node node-03 | grep -A5 Conditions
  MemoryPressure   True    Mon, 08 Aug 2026 09:58:00 +0000   ...   KubeletHasInsufficientMemory

$ kubectl get events -n payments --sort-by='.lastTimestamp' | tail -5
LAST SEEN   TYPE      REASON      OBJECT                          MESSAGE
30s         Warning   Evicted     pod/payments-api-7d4f9c-xk2q9   The node was low on resource: memory.
```

## Practice Questions

1. A pod shows `CrashLoopBackOff` with 0 restarts logged for the current container instance. Which command shows you the logs from BEFORE the last crash, and why is `kubectl logs` alone insufficient here?
2. `kubectl exec -it my-pod -- sh` fails with "executable file not found in $PATH." What's happening, and what's the modern kubectl-native way to debug a shell-less (distroless) container?
3. A container exits with code 137. What does this exit code decompose to, and what ADDITIONAL command/field would you check to confirm it was specifically an OOM kill versus a manual `docker kill`?
4. When would you reach for `crictl` instead of `kubectl` or `docker` to debug a container issue? Give a concrete scenario where `kubectl` itself is unavailable or misleading.
5. A pod has two containers (`app` and `istio-proxy`). What happens if you run `kubectl exec -it my-pod -- sh` without `-c`, and how do you target the specific container you need?
6. Write a command to tail logs across every pod matching `app=checkout` simultaneously, with each line prefixed by its source pod name.
7. `kubectl describe pod` shows nothing useful in Events, and `kubectl logs` shows nothing either — the pod is stuck in `Pending`. What's the next thing you'd check, and why wouldn't logs show this class of problem at all?
8. Explain the difference in what `docker inspect` versus `docker logs` each tell you when diagnosing why a container stopped, and give an example of a failure only visible via `inspect`.
9. You SSH onto a Kubernetes node directly (API server is down) and need to find out which containers are currently running and their exit history. Walk through the `crictl` commands you'd use.
10. Describe the general debugging decision tree you'd follow for: (a) a pod that never starts, (b) a pod that crash-loops, (c) a pod that's running but the app inside is misbehaving. Name the specific command for each stage.

## Interview Key Points

- `kubectl logs --previous` is the single most-missed command by less experienced engineers debugging crash loops — the current container instance often has zero useful log history because it just (re)started.
- Exit code 137 = 128 + SIGKILL(9) — always cross-check `OOMKilled` (via `docker inspect` / `crictl inspect` / `kubectl describe pod`'s "Last State" section) rather than assuming OOM from the exit code alone; 137 can also result from a manual kill or node preemption.
- `kubectl describe pod`'s Events section captures failures that never reach application logs at all — scheduling failures, image pull errors, failed probes, evictions. Always check it before assuming "no logs = no problem."
- Ephemeral debug containers (`kubectl debug --target=`) are the modern, kubectl-native answer for distroless/minimal images with no shell — know this over older workarounds (copying a static binary in, etc.).
- `crictl` operates at the container-runtime (CRI) level, one layer below `kubectl`/`docker` — it's the fallback when the Kubernetes control plane itself is unreachable and you're debugging directly on a node.
- `-c <container>` is required for any `kubectl logs`/`kubectl exec` against a multi-container pod (very common with service meshes injecting sidecars like `istio-proxy`) — forgetting it is a common real-world stumble.
- Node-level signals (`MemoryPressure`, `DiskPressure` conditions via `kubectl describe node`, or evictions via `kubectl get events`) often explain pod-level symptoms that look like application bugs at first glance — a senior debugger checks the node, not just the pod.
