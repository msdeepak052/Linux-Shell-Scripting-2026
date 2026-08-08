# TCP/IP Fundamentals & the OSI Model

The mental map every other networking topic in this stage hangs off — encapsulation, layers, and where a given tool/problem actually lives.

## Explanation

**Why this matters day-to-day**: when something breaks ("can't reach the service"), the fastest diagnosis path is "which layer is failing?" — cable/interface down (L1/L2), no route/IP (L3), port closed/RST (L4), TLS handshake failing (L4/L5-ish), or the app returning a 500 (L7). Senior engineers triage by layer instinctively; that's the entire point of knowing this model.

### The OSI model (7 layers) — theoretical reference

| Layer | Name | Deals with | Example |
|---|---|---|---|
| 7 | Application | End-user protocols | HTTP, DNS, SSH, SMTP |
| 6 | Presentation | Encoding/encryption/serialization | TLS, JSON/protobuf encoding |
| 5 | Session | Session establishment/teardown | TLS handshake, sockets sessions |
| 4 | Transport | End-to-end delivery, ports | TCP, UDP |
| 3 | Network | Logical addressing, routing | IP, ICMP, routers |
| 2 | Data Link | Physical addressing on a local segment | Ethernet, MAC addresses, switches, ARP |
| 1 | Physical | Bits on the wire/air | Cables, NICs, radio |

Mnemonic: "**A**ll **P**eople **S**eem **T**o **N**eed **D**ata **P**rocessing" (7→1).

### The TCP/IP model (4-5 layers) — what's actually implemented

OSI is taught in school; **no OS actually implements 7 discrete layers**. Real systems (Linux included) implement the **TCP/IP (DoD) model**, which collapses OSI's top three layers into one "Application" layer:

| TCP/IP layer | Roughly maps to OSI | Linux reality |
|---|---|---|
| Application | 5, 6, 7 | Your process, using sockets |
| Transport | 4 | TCP/UDP in the kernel |
| Internet | 3 | IP routing, `ip route` |
| Link (Network Access) | 1, 2 | NIC driver, Ethernet, ARP |

**Interview framing**: "OSI is a 7-layer *reference/teaching* model; TCP/IP is the 4-layer model that's *actually implemented*. When people say 'Layer 3 problem' or 'Layer 7 load balancer' they're using OSI numbering as shorthand even on TCP/IP systems — the numbering stuck because it's a universally understood vocabulary."

### Encapsulation — what actually happens to your data

Each layer wraps ("encapsulates") the layer above it with its own header (and sometimes trailer) as data moves down the stack on send, and strips headers back off on receive:

```
[Ethernet Hdr [ IP Hdr [ TCP/UDP Hdr [ Application Data ] ] ] Eth Trailer]
```

- Application data → **Segment** (TCP) or **Datagram** (UDP) — adds source/dest **port**
- Segment/Datagram → **Packet** — adds source/dest **IP address**
- Packet → **Frame** — adds source/dest **MAC address**
- Frame → **Bits** — put on the wire

This terminology (segment/packet/frame) is a very common "do you actually know this or just use the words interchangeably" interview trap.

### TCP vs UDP — the layer-4 decision that matters most

| | TCP | UDP |
|---|---|---|
| Connection | Connection-oriented (3-way handshake: SYN, SYN-ACK, ACK) | Connectionless |
| Reliability | Guaranteed delivery, ordering, retransmission | None — fire and forget |
| Overhead | Higher (headers, ACKs, congestion control) | Minimal |
| Use cases | HTTP(S), SSH, databases, anything needing correctness | DNS queries, video/voice streaming, DHCP, metrics |

**Bottom line**: use TCP when correctness/ordering matters more than latency; use UDP when latency/throughput matters more than occasional loss, or when the application layer handles its own reliability (e.g., QUIC/HTTP3 builds reliability on top of UDP).

### The TCP 3-way handshake (and teardown)

```
Client                     Server
  |------ SYN ------------->|
  |<---- SYN-ACK ------------|
  |------ ACK ------------->|
        (connection established)
```
Teardown uses FIN/ACK exchanges (4-way) or an abrupt RST on error/reset. This is directly why `ss`/`tcpdump` output shows `SYN_SENT`, `ESTABLISHED`, `FIN_WAIT`, `TIME_WAIT`, etc. — those are literal TCP state-machine states (covered in depth in the Ports & Sockets file).

### Private vs public IP ranges (quick reference)

`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` are RFC1918 private ranges — never routable on the public internet, always require NAT to reach outside. Seeing `10.x.x.x` in output tells you immediately you're inside a private network/VPC.

## Hands-On Examples

**1. Watching the 3-way handshake with tcpdump**
```bash
$ sudo tcpdump -i eth0 -n host 10.0.1.20 and port 443 -c 6
14:02:11.100201 IP 10.0.1.5.51422 > 10.0.1.20.443: Flags [S], seq 123456
14:02:11.100950 IP 10.0.1.20.443 > 10.0.1.5.51422: Flags [S.], seq 987654, ack 123457
14:02:11.101003 IP 10.0.1.5.51422 > 10.0.1.20.443: Flags [.], ack 987655
14:02:11.102411 IP 10.0.1.5.51422 > 10.0.1.20.443: Flags [P.], seq 1:518, ack 1
14:02:11.150233 IP 10.0.1.20.443 > 10.0.1.5.51422: Flags [P.], seq 1:2921, ack 518
14:02:11.150900 IP 10.0.1.5.51422 > 10.0.1.20.443: Flags [.], ack 2921
```
`[S]` = SYN, `[S.]` = SYN-ACK, `[.]` = ACK — you can literally see the handshake in the flags column.

**2. Seeing TCP vs UDP side by side**
```bash
$ ss -tulnp | head -6
Netid  State   Local Address:Port   Peer Address:Port  Process
udp    UNCONN  0.0.0.0:68           0.0.0.0:*           dhclient
udp    UNCONN  127.0.0.53:53        0.0.0.0:*           systemd-resolved
tcp    LISTEN  127.0.0.53:53        0.0.0.0:*           systemd-resolved
tcp    LISTEN  0.0.0.0:22           0.0.0.0:*           sshd
tcp    LISTEN  0.0.0.0:8080         0.0.0.0:*           java
```
DHCP (68) and local DNS stub resolution (53) run over UDP; SSH and the app server are TCP.

**3. Identifying which layer a fault is at — dead interface (L1/L2)**
```bash
$ ip link show eth0
2: eth0: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN mode DEFAULT
    link/ether 02:42:ac:11:00:05 brd ff:ff:ff:ff:ff:ff
```
`state DOWN` with no carrier — this is a Layer 1/2 problem (cable, driver, switch port), not a routing or DNS issue. No amount of `ping`ing will fix this until the link comes up.

**4. Identifying a Layer 3 (routing) failure**
```bash
$ ping -c 2 10.0.5.9
PING 10.0.5.9 (10.0.5.9) 56(84) bytes of data.
From 10.0.1.1 icmp_seq=1 Destination Host Unreachable
From 10.0.1.1 icmp_seq=2 Destination Host Unreachable
```
The response comes from the local gateway (`10.0.1.1`), not the destination — this router has no route to `10.0.5.9`. Classic Layer 3 symptom.

**5. Identifying a Layer 4 failure (host is reachable, port is closed)**
```bash
$ ping -c 1 10.0.1.20
64 bytes from 10.0.1.20: icmp_seq=1 ttl=63 time=0.412 ms

$ curl -v telnet://10.0.1.20:8080
* Trying 10.0.1.20:8080...
* connect to 10.0.1.20 port 8080 failed: Connection refused
```
L3 is fine (ping succeeds — host is up), but L4 fails: nothing is listening on 8080, or a firewall is sending RST. This distinction (host reachable vs port reachable) is asked constantly in interviews.

**6. Identifying a Layer 7 failure (everything below works, app is broken)**
```bash
$ curl -v https://api.internal.example.com/health
*   Trying 10.0.1.20:443...
* Connected to api.internal.example.com (10.0.1.20) port 443
* TLS handshake completed
> GET /health HTTP/1.1
> Host: api.internal.example.com
< HTTP/1.1 500 Internal Server Error
```
TCP connects, TLS completes — L1 through L5 are all fine. The failure is purely Layer 7 (application logic) — the fix is in app logs, not network tooling.

## Practice Questions

1. Explain the difference between the OSI model and the TCP/IP model — why do people still say "Layer 7 load balancer" if TCP/IP only has 4-5 layers?
2. Walk through encapsulation: what gets added to your data as it goes from an application write() down to bits on the wire, and what are the correct names for the unit of data at each stage (segment/packet/frame)?
3. A colleague says "I can `ping` the server but `curl` times out." Which OSI/TCP-IP layer is most likely broken, and what would you check next?
4. Draw (in words) the TCP three-way handshake, and explain what a `tcpdump` capture showing only `[S]` packets with no `[S.]` reply tells you.
5. Why is DNS typically UDP but occasionally falls back to TCP? What does that tell you about protocol choice trade-offs?
6. You see `From 10.0.1.1 icmp_seq=1 Destination Host Unreachable` when pinging a remote host. Whose IP is `10.0.1.1` in that message, and what does it tell you about where the failure is?
7. What's the practical difference between "connection refused" and "connection timed out" when connecting to a port — which layer/cause does each point to?
8. Why is `10.0.0.0/8` traffic never seen on the public internet, and what has to happen for a host inside that range to reach the internet?
9. A request reaches the server (TCP connects, TLS completes) but returns HTTP 500. Which layer owns this bug, and why would `tcpdump` or `ping` be the wrong tool to debug it further?
10. Explain why TCP guarantees ordering/delivery but UDP doesn't, and give two real production use cases where you'd deliberately choose UDP despite that.

## Interview Key Points

- **OSI (7 layers) is a teaching/reference model; TCP/IP (4 layers) is what's actually implemented** — interviewers probe whether you know this distinction or just recite "7 layers" by rote.
- **Layer-based triage is the real skill being tested**: given symptoms (ping works/doesn't, port open/closed, TLS ok, HTTP error), can you localize the fault to L1/2 (link), L3 (routing), L4 (port/firewall), or L7 (app)?
- Know the encapsulation unit names cold: **segment** (TCP)/**datagram** (UDP) at L4, **packet** at L3, **frame** at L2 — mixing these up is an easy tell of surface-level knowledge.
- **"Ping works but the app doesn't" is the single most common troubleshooting scenario asked** — it isolates L3 connectivity from L4 (port) or L7 (app) failure, and interviewers want to hear you say that explicitly.
- Know the 3-way handshake (SYN, SYN-ACK, ACK) and be able to read handshake flags in a `tcpdump`/Wireshark capture — this comes up whenever TCP or troubleshooting is discussed.
- TCP vs UDP trade-off (reliability/ordering vs low overhead/latency) — always have concrete examples ready (HTTP/SSH/DB = TCP; DNS queries/streaming/DHCP = UDP).
- RFC1918 private ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) should be instantly recognizable — seeing one in output tells you you're inside a private network needing NAT to reach the internet.
- "Connection refused" (L4, RST received, nothing listening or explicitly rejected) vs "connection timed out" (packets going nowhere — firewall silently dropping, or no route) is a distinction senior candidates are expected to explain unprompted.
