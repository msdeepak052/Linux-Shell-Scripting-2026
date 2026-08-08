# Ports & Sockets: `ss`, `netstat`, Listening vs Established

Finding out what's actually listening, what's connected to what, and diagnosing "port already in use" or "can't connect" problems.

## Explanation

A **socket** is the OS-level endpoint of a network connection, uniquely identified by the tuple `(protocol, local IP, local port, remote IP, remote port)`. A **port** is just a 16-bit number (0-65535) that lets multiple services/connections share one IP address — the kernel uses the port to route incoming packets to the right listening process.

### Port ranges

- **0-1023**: "well-known" / privileged ports — require root (or `CAP_NET_BIND_SERVICE`) to bind on Linux. E.g., 22 (SSH), 80 (HTTP), 443 (HTTPS).
- **1024-49151**: registered ports — commonly used by specific applications by convention (e.g., 3306 MySQL, 5432 PostgreSQL, 6379 Redis) but not kernel-enforced.
- **49152-65535**: ephemeral ports — the kernel picks from this range automatically for the **client side** of an outbound connection.

### TCP socket states — the ones that actually matter

| State | Meaning |
|---|---|
| `LISTEN` | Process is bound to a port and waiting for incoming connections (server side) |
| `SYN_SENT` | Client sent SYN, waiting for SYN-ACK |
| `SYN_RECV` | Server received SYN, sent SYN-ACK, waiting for final ACK |
| `ESTABLISHED` | Handshake complete, data can flow — an actual active connection |
| `TIME_WAIT` | Connection closed locally, waiting (usually 60s) to absorb any stray packets before fully releasing the port |
| `CLOSE_WAIT` | Remote side closed, but **local app hasn't called close() yet** — a pile of these means an app-level bug (leaked connections) |

A **listening** socket is not a connection — it's a process saying "I'm ready to accept." An **established** socket is an actual live conversation between two specific endpoints. Confusing these ("nginx is listening on 8080, so it must be handling traffic") is a common junior mistake — you have to check for `ESTABLISHED` entries to know if there's real traffic.

### `ss` vs `netstat`

`netstat` (from the old net-tools package) is deprecated on most modern distros — it reads and parses `/proc/net/tcp` line by line, which gets slow with thousands of connections. `ss` (socket statistics, from iproute2) talks to the kernel more directly via netlink and is dramatically faster, especially on busy servers.

### Which one should you actually use? (Decision rule)

| Situation | Tool |
|---|---|
| Any modern system, day-to-day use | `ss` — faster, more detail, actively maintained |
| Legacy system where only `netstat` is installed, or muscle-memory/old scripts | `netstat` (fine, just know it's legacy) |
| Need process name/PID owning a port | `ss -tulnp` or `netstat -tulnp` (both need root/sudo to see other users' process names) |

**Bottom line**: default to `ss` on every modern system — `netstat` is legacy tooling kept around for compatibility and muscle memory, not because it's still the better tool.

### Reading `ss` flags

- `-t` TCP, `-u` UDP, `-l` listening only, `-n` numeric (skip DNS/service-name resolution — much faster and avoids DNS-related hangs), `-p` show owning process (needs root for other users' processes), `-a` all sockets (listening + established)

## Hands-On Examples

**1. Listing all listening TCP/UDP ports with owning process**
```bash
$ sudo ss -tulnp
Netid  State   Local Address:Port    Peer Address:Port   Process
udp    UNCONN  127.0.0.53%lo:53      0.0.0.0:*           users:(("systemd-resolve",pid=612,fd=13))
tcp    LISTEN  0.0.0.0:22            0.0.0.0:*           users:(("sshd",pid=891,fd=3))
tcp    LISTEN  127.0.0.1:5432        0.0.0.0:*           users:(("postgres",pid=1204,fd=5))
tcp    LISTEN  0.0.0.0:8080          0.0.0.0:*           users:(("java",pid=2210,fd=44))
```
Note PostgreSQL bound to `127.0.0.1` only — it's not reachable from other hosts at all, by design (a very common "why can't I connect from another server" answer).

**2. Showing established connections (real active traffic)**
```bash
$ ss -tn state established
State    Recv-Q  Send-Q   Local Address:Port      Peer Address:Port
ESTAB    0       0        10.0.1.5:8080           10.0.1.20:51422
ESTAB    0       0        10.0.1.5:8080           10.0.1.21:38810
ESTAB    0       0        10.0.1.5:22             203.0.113.44:60122
```
This is how you check if a "listening" service actually has live clients right now.

**3. Finding what's using a specific port (classic "port already in use")**
```bash
$ sudo ss -tlnp 'sport = :8080'
State   Local Address:Port    Peer Address:Port   Process
LISTEN  0.0.0.0:8080          0.0.0.0:*           users:(("java",pid=2210,fd=44))

$ sudo kill 2210    # or find the right process and restart it properly
```

**4. Counting connections by state (spotting a `CLOSE_WAIT` leak)**
```bash
$ ss -tan | awk '{print $1}' | sort | uniq -c | sort -rn
    412 ESTAB
    203 TIME_WAIT
     89 CLOSE_WAIT
      4 LISTEN
```
89 sockets stuck in `CLOSE_WAIT` on an app server usually means the application isn't calling `close()` on its sockets — a real resource-leak bug, not a network problem. This exact pattern is a classic "diagnose the outage" interview scenario.

**5. Legacy `netstat` equivalent (for comparison / older systems)**
```bash
$ sudo netstat -tulnp
Proto Recv-Q Send-Q Local Address    Foreign Address   State    PID/Program name
tcp        0      0 0.0.0.0:22      0.0.0.0:*         LISTEN   891/sshd
tcp        0      0 0.0.0.0:8080    0.0.0.0:*         LISTEN   2210/java
```

**6. Diagnosing "can't reach service on port 8080" — is it even listening?**
```bash
$ ss -tlnp | grep 8080
# (no output — nothing is listening on 8080 at all)

$ sudo systemctl status myapp
● myapp.service - My Application
     Active: failed (Result: exit-code) since Sat 2026-08-08 14:01:02 UTC
```
The port isn't open because the service crashed — `ss` proved it's not a firewall/network issue at all, saving you from chasing the wrong layer.

**7. Distinguishing "bound to localhost only" vs "bound to all interfaces" (very common misconfig)**
```bash
$ ss -tlnp | grep 5432
tcp   LISTEN  127.0.0.1:5432   0.0.0.0:*   users:(("postgres",...))
```
`127.0.0.1:5432` means Postgres only accepts connections originating from the same host — remote clients get "connection refused" even though the process is clearly running and listening. Fix (if remote access is intended) is `listen_addresses = '*'` in `postgresql.conf`, not a firewall change.

**8. Checking ephemeral port exhaustion (rare but real production issue)**
```bash
$ ss -s
Total: 28419 (kernel 0)
TCP:   26200 (estab 180, closed 25998, orphaned 12, timewait 25901)

$ cat /proc/sys/net/ipv4/ip_local_port_range
32768 60999
```
Tens of thousands of connections stuck in `timewait` can, in extreme high-churn scenarios (e.g., a misbehaving client opening a new connection per request instead of reusing one), exhaust the ephemeral port range on the client side — worth knowing `net.ipv4.tcp_tw_reuse` and connection pooling as the standard fixes.

## Practice Questions

1. What's the practical difference between a socket in `LISTEN` state and one in `ESTABLISHED` state, and why does "the service is listening" not prove "the service is receiving traffic"?
2. Write the `ss` command to find which process (with PID) owns port 8080, and explain why it typically needs `sudo`.
3. A server shows 90 sockets stuck in `CLOSE_WAIT` for one application. What does that state mean, and whose responsibility (kernel vs application code) is it to fix?
4. Why is `ss` generally preferred over `netstat` on modern systems? What's actually different about how each gathers its data?
5. You find a service listening on `127.0.0.1:5432` instead of `0.0.0.0:5432`. What's the practical consequence, and how is this different from a firewall blocking the port?
6. Explain what an ephemeral port is, give its typical range on Linux, and describe a real scenario where a system could run out of them.
7. Given `ss -tan | grep :443`, how would you count how many distinct remote IPs currently have an established connection to your service on port 443?
8. What's the difference between a "well-known" port and a "registered" port, and why does binding to port 80 require elevated privileges while port 8080 doesn't?
9. A deploy script checks "is my new service up" by grepping `ss -tlnp` for the port — what's a scenario where this check would give a false positive (port appears open, but the service is still broken)?
10. Explain `TIME_WAIT` — why does the kernel hold a closed connection's port in this state instead of releasing it immediately, and why is a large number of them not automatically a problem?

## Real Interview Questions (Company-Attributed)

- "How do you check network details and traffic flow on a system, and which command would you use?" — asked at *an unnamed company (via community-sourced interview notes)*
- "Explain the use of `netstat`." — asked at *Sigmoid* (part of a rapid-fire "explain these Linux commands" interview round)

## Interview Key Points

- **LISTEN vs ESTABLISHED is the #1 conceptual check** — a listening socket only means "ready to accept," not "actively serving traffic"; always be ready to explain the distinction with a concrete example.
- `ss` over `netstat` — know *why* (netlink vs parsing `/proc/net/tcp`), not just "ss is newer." Being able to explain the mechanism is what separates a senior answer from a memorized one.
- **`CLOSE_WAIT` pileups indicate an application bug** (not calling `close()`), not a network/OS issue — this is a favorite "diagnose the root cause" interview scenario.
- **Binding to `127.0.0.1` vs `0.0.0.0`** is one of the most common real "why can't I connect remotely" root causes, distinct from and often confused with a firewall problem — always check both.
- Privileged ports (<1024) requiring root (or `CAP_NET_BIND_SERVICE`) is a frequently-asked "why does my app need sudo to bind port 80" question — know the capability-based alternative to running as root.
- `ss -s` for a fast connection-state summary is a good answer to "how would you get a quick health snapshot of connection load on a busy server."
- Ephemeral port range and `TIME_WAIT` accumulation under high churn is a senior-level topic (`tcp_tw_reuse`, connection pooling, `ip_local_port_range`) — worth knowing exists even if you haven't hit it personally.
- Always frame "port checking" as one step in a larger diagnostic chain: is it listening (`ss`) → is it reachable (firewall/routing) → does the app actually respond (`curl`) — interviewers want to see you sequence tools, not just name them.
