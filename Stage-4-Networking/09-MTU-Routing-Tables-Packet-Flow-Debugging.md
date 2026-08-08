# MTU, Routing Tables, and Packet-Flow Debugging

Below the application and even below the TCP handshake, packets have to be correctly sized and correctly routed — MTU mismatches and routing table errors cause some of the most confusing, intermittent-looking production issues.

## Explanation

**MTU (Maximum Transmission Unit)**: the largest packet size (in bytes) an interface will pass without fragmenting, at L2/L3. Standard Ethernet MTU is **1500**; jumbo frames use **9000** (common on storage/backend networks for throughput); tunnel overlays (VXLAN, IPsec, WireGuard, GRE) add encapsulation overhead, which **reduces the effective/inner MTU** available to the original packet — e.g., a VXLAN header eats ~50 bytes, so the inner interface may need MTU 1450 to avoid fragmentation. If a packet exceeds a link's MTU: IPv4 either fragments (if the "don't fragment" bit isn't set) or the router drops it and sends back an ICMP "Fragmentation Needed" (type 3, code 4) message — this is **PMTUD (Path MTU Discovery)**. The classic failure mode: a firewall blocks that ICMP message, so the sender never learns to shrink its packets — connections work fine for small requests (DNS, TCP handshake) but hang/timeout on larger payloads (TLS handshake certs, large HTTP responses) — "black hole" PMTUD.

**Routing tables**: the kernel's table of "for destination network X, send via gateway Y out interface Z." Viewed via `ip route` (modern) or `route -n` (legacy). Entries are matched by **longest prefix match** — a more specific route (e.g., `/32`) always wins over a less specific one (e.g., `/0`, the default route) regardless of order in the table. The default route (`0.0.0.0/0` for IPv4, shown as `default` in `ip route`) is where traffic goes when no more specific route matches. Multiple routing tables + policy-based routing (`ip rule`) exist for advanced cases (e.g., route differently based on source IP) — most servers only use the `main` table.

**Packet flow through a Linux host** (simplified, roughly netfilter/iptables order): incoming packet → NIC → `PREROUTING` (DNAT happens here) → **routing decision** (is this for us, or should it be forwarded?) → if for us: `INPUT` chain → local process; if forwarding: `FORWARD` chain → `POSTROUTING` (SNAT/MASQUERADE happens here) → out NIC. Understanding this order explains why DNAT rules must be in `PREROUTING` (before routing decides where the packet goes) while SNAT/MASQUERADE must be in `POSTROUTING` (after routing, right before it leaves).

**Debugging packet flow tools**: `ip route get <dest>` shows exactly which route/interface/source-IP the kernel would choose for a destination, without sending anything — the fastest way to answer "which interface will this traffic actually use?" `ip route show table all` / `ip rule` for policy routing setups. `traceroute`/`mtr` for the external path (see file 07). `tcpdump` to see actual fragmentation or ICMP "frag needed" messages on the wire. `ping -M do -s <size>` to actively probe path MTU (do = "don't fragment," forces an ICMP error instead of silent fragmentation, letting you binary-search the working size).

**Common MTU/routing symptoms to recognize**: small requests work, large ones hang → PMTUD black hole. Container/pod can reach some hosts but not others across an overlay → MTU mismatch on the overlay interface. Host has two NICs / multiple default gateways and traffic goes out the "wrong" one → routing table / route metric issue. Service works from one subnet but not another → missing or asymmetric route (return traffic takes a different, filtered path).

## Hands-On Examples

**1. Inspecting interface MTU**
```bash
$ ip link show eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP
    link/ether 02:42:ac:11:00:02 brd ff:ff:ff:ff:ff:ff

$ ip link show vxlan0
5: vxlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UP
    # 1500 (underlay) - 50 (VXLAN+outer IP/UDP header) = 1450 inner MTU
```

**2. Probing path MTU with ping's don't-fragment flag**
```bash
$ ping -M do -s 1472 -c 2 10.0.5.20
PING 10.0.5.20 (10.0.5.20) 1472(1500) bytes of data.
1480 bytes from 10.0.5.20: icmp_seq=1 ttl=63 time=0.412 ms
# 1472 + 8 (ICMP) + 20 (IP) = 1500, full MTU works fine

$ ping -M do -s 1473 -c 2 10.0.5.20
PING 10.0.5.20 (10.0.5.20) 1473(1501) bytes of data.
ping: local error: message too long, mtu=1500
# confirms 1500 is the hard ceiling on this path — anything over fails immediately
```

**3. Classic PMTUD black hole symptom — small requests work, TLS hangs**
```bash
$ curl -v https://big-payload-api.example.com/health
< HTTP/1.1 200 OK   # small response — works fine

$ curl -v https://big-payload-api.example.com/large-report
* TLS handshake, Client hello (1)
# ... hangs indefinitely, times out
# root cause: TLS ServerHello + cert chain > path MTU, ICMP "frag needed" is
# being dropped by a firewall somewhere in between, sender never shrinks packets
$ tcpdump -i eth0 -nn 'icmp'
# (nothing captured) -- confirms the "frag needed" ICMP never arrives back
```

**4. Reading and interpreting the routing table**
```bash
$ ip route show
default via 10.0.0.1 dev eth0 proto dhcp metric 100
10.0.0.0/24 dev eth0 proto kernel scope link src 10.0.0.15
10.0.5.0/24 via 10.0.0.254 dev eth0 metric 50   # more specific route to internal subnet
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1
```

**5. `ip route get` — resolving exactly which route/source-IP will be used**
```bash
$ ip route get 10.0.5.20
10.0.5.20 via 10.0.0.254 dev eth0 src 10.0.0.15 uid 1000
    cache
# clear answer: this traffic exits via eth0, next-hop 10.0.0.254, source IP 10.0.0.15

$ ip route get 8.8.8.8
8.8.8.8 via 10.0.0.1 dev eth0 src 10.0.0.15 uid 1000
    cache
# falls through to the default route since no more specific match exists
```

**6. Diagnosing a "wrong interface" issue on a dual-NIC host**
```bash
$ ip route show
default via 10.0.0.1 dev eth0 metric 100
default via 172.16.0.1 dev eth1 metric 200   # backup/secondary NIC, higher metric = lower priority

$ ip route get 1.1.1.1
1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.15
# correctly using eth0 (lower metric wins); if eth0 went down unexpectedly,
# traffic would silently shift to eth1 -- worth checking during "wrong source IP" reports
```

**7. Watching fragmentation happen live in tcpdump**
```bash
$ sudo tcpdump -i eth0 -nn 'host 10.0.5.20 and (ip[6:2] & 0x1fff != 0)'
10:05:01.100 IP 10.0.0.15 > 10.0.5.20: frag 12345:1480@0+
10:05:01.100 IP 10.0.0.15 > 10.0.5.20: frag 12345:1480@1480
# packet got fragmented into two pieces -- if a firewall in the path drops
# non-first fragments (common security hardening), this connection will hang
```

**8. Fixing an MTU mismatch on a VXLAN/overlay interface (Kubernetes CNI style)**
```bash
$ ip link show flannel.1
8: flannel.1: mtu 1500 qdisc noqueue state UNKNOWN   # WRONG: should be 1450 for VXLAN overlay
# symptom: small pings between pods work, large curl responses between pods hang

$ ip link set flannel.1 mtu 1450
$ ip link show flannel.1
8: flannel.1: mtu 1450 qdisc noqueue state UNKNOWN   # fixed
# in production this is normally set via CNI config (e.g., flannel's net-conf.json),
# manual `ip link set` is just for live debugging/confirmation
```

## Practice Questions

1. What is Path MTU Discovery, and what specific symptom pattern (which requests work, which hang) tells you you're looking at a PMTUD black hole?
2. Why does blocking ICMP entirely at a firewall (a common "security hardening" habit) actively break PMTUD? What ICMP type/code specifically needs to be allowed through?
3. A Kubernetes pod on a VXLAN overlay network can `ping` a pod on another node fine, but a `curl` fetching a large JSON response hangs. What's your hypothesis, and how would you confirm it with `ip link` and `ping -M do`?
4. Explain longest-prefix-match in routing table lookups. If you have both `10.0.5.0/24 via X` and `default via Y`, which one wins for a destination of `10.0.5.20`, and why?
5. What does `ip route get <ip>` tell you that `ip route show` alone doesn't, and why is it the fastest first command to run when someone says "traffic is going out the wrong interface"?
6. A host has two NICs, each with a default route at different metrics. Explain what "metric" means here and how the kernel decides which default route to actually use.
7. Walk through Netfilter/iptables packet flow: at which chain does DNAT happen, at which chain does SNAT/MASQUERADE happen, and why does that ordering matter relative to the routing decision?
8. Using `tcpdump`, how would you determine whether a given connection's packets are being fragmented at the IP layer, and why might a firewall dropping non-initial fragments cause a connection to hang even though the first fragment arrives fine?
9. You inherit a VXLAN-based overlay network where the underlay MTU is 1500. What inner/overlay MTU should you configure and why (show the arithmetic)?
10. A service works fine when accessed from Subnet A but times out from Subnet B, despite both having a route to it. What are two distinct root causes (one routing-related, one MTU-related) you'd check, and how would you distinguish between them?

## Interview Key Points

- **PMTUD black holes are one of the highest-value "gotcha" scenarios** to know cold: small requests succeed, large payloads hang — caused by a firewall dropping the ICMP "Fragmentation Needed" (type 3, code 4) reply, so the sender never learns to shrink packets. This is a favorite senior-level troubleshooting question.
- Know the concrete MTU arithmetic for overlays: standard Ethernet 1500, VXLAN overhead ~50 bytes → inner MTU 1450 (or IPsec/GRE/WireGuard equivalents) — being able to state real numbers, not just "overlays need smaller MTU," signals real experience.
- **Longest prefix match, not table order**, determines which route wins — a very commonly misunderstood point; a `/32` or `/24` route always beats `/0` (default) for a matching destination regardless of where it appears in `ip route show` output.
- `ip route get <dest>` is the fast, authoritative, side-effect-free way to answer "which interface/source-IP/gateway will this traffic actually use" — know this over manually reading the whole table and mentally simulating the match.
- Understand **why blanket ICMP blocking is a security anti-pattern**: it breaks PMTUD (silent hangs on large payloads) and breaks basic reachability diagnostics — the nuanced answer is "allow specific needed ICMP types (echo, frag-needed, TTL-exceeded), don't blanket-block ICMP."
- Netfilter chain order (`PREROUTING` → routing decision → `INPUT`/`FORWARD` → `POSTROUTING`) explains *why* DNAT must happen before the routing decision and SNAT after it — a good "do you actually understand the packet path" litmus test beyond memorized iptables syntax.
- Route metrics determine priority among multiple matching routes (e.g., two default routes on a dual-NIC host) — lower metric wins; relevant for diagnosing "traffic silently failed over to the wrong/backup NIC" incidents.
- Symptom-to-cause pattern matching is what's really being tested: "works from A, not from B" → asymmetric/missing route; "small payloads OK, large ones hang" → MTU/PMTUD; "everything to one IP fails, others fine" → check `ip route get` for a bad specific route entry.
