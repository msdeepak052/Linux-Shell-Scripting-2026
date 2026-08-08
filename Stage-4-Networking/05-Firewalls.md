# Firewalls: `iptables`, `nftables`, `firewalld`, `ufw`

Four tools, one underlying kernel subsystem — resolving exactly when to use which, because this is one of the most confused areas in Linux networking.

## Explanation

The single most important thing to understand: **all four of these are just different front-ends/interfaces to packet filtering in the Linux kernel.** They are not competing independent firewall engines — they're layers of abstraction over the same underlying capability (historically Netfilter/iptables, now Netfilter/nftables).

### The kernel layer: Netfilter → iptables (legacy) → nftables (modern)

- **iptables** talks to the kernel's **Netfilter** hooks using the older `x_tables` framework. Rules are organized into **tables** (`filter`, `nat`, `mangle`, `raw`) and **chains** (`INPUT`, `OUTPUT`, `FORWARD` for the filter table). Every rule-set change historically meant **flushing and reloading the entire ruleset**, which is slow and can cause a momentary gap in enforcement at scale.
- **nftables** is the modern successor, replacing `x_tables` since kernel 3.13+, and is now the actual default backend on current major distros (Debian, RHEL 8+, Ubuntu). It supports atomic rule updates, a more expressive single syntax (no separate `iptables`/`ip6tables`/`arptables`/`ebtables` binaries), and better performance with large rule sets. On modern systems, `iptables` commands are frequently just a **compatibility shim** (`iptables-nft`) translating to nftables under the hood.

### The management layer: firewalld and ufw

Both `firewalld` and `ufw` don't replace iptables/nftables — they sit **on top** of them as a friendlier configuration/management layer, and both today typically use nftables as their actual backend.

- **firewalld** (RHEL/CentOS/Fedora default) — introduces the concept of **zones** (`public`, `internal`, `trusted`, `dmz`, etc.) where each network interface is assigned a trust level, and rules apply per-zone. Supports **runtime** vs **permanent** rule changes (`--permanent` flag) — a very common gotcha (see below). Manages rules via `firewall-cmd`.
- **ufw** (Uncomplicated Firewall, Ubuntu/Debian default) — deliberately minimal, simple `allow`/`deny` syntax, no zone concept — designed for straightforward host-based filtering on servers/desktops without needing to think about the underlying rule structure.

### Which one should you actually use? (Decision rule)

| Situation | Tool | Why |
|---|---|---|
| Ubuntu/Debian server or desktop, straightforward host firewall | **ufw** | Simple syntax, distro-default, sufficient for "allow SSH/HTTP, deny else" |
| RHEL/CentOS/Fedora, especially with multiple network zones (e.g., a box with both a public and internal NIC) | **firewalld** | Zone model matches multi-homed/enterprise network segmentation naturally, distro-default |
| Writing custom, complex, or performance-sensitive rules directly; modern greenfield systems | **nftables** (raw) | Current kernel-native standard, atomic updates, single unified syntax, best performance at scale |
| Maintaining/reading legacy scripts, older systems, or infra you didn't build that still uses raw rules | **iptables** | Still extremely common in the wild (legacy playbooks, older containers/base images, Docker's own rule injection) — you must be able to read it even if you wouldn't choose it new |
| Container/orchestration environments (Docker, Kubernetes CNI) | Usually **iptables/nftables directly**, injected by the platform | Docker and kube-proxy manipulate iptables/nftables rules directly — firewalld/ufw commonly get disabled or actively conflict here |

**Bottom line**: for new work, pick the *distro default management layer* — **ufw on Ubuntu/Debian, firewalld on RHEL/CentOS/Fedora** — and drop to raw **nftables** only when you need custom/complex rules those layers can't express; treat **iptables** as a read-and-maintain legacy skill, not a first choice for new systems, and be aware container platforms often manage iptables/nftables rules directly, which is a common source of "firewalld says it's allowed but it's still blocked" confusion.

### Critical gotchas

- **firewalld runtime vs permanent**: `firewall-cmd --add-port=8080/tcp` (no `--permanent`) applies **immediately but is lost on reload/reboot**. `firewall-cmd --add-port=8080/tcp --permanent` persists **but doesn't take effect until `firewall-cmd --reload`** (or next boot). Forgetting one or the other is the single most common firewalld mistake in real operations — you need **both** for an immediate + persistent change: apply runtime for now, `--permanent` for after reload, then optionally `--reload` to sync them.
- **ufw and Docker conflict**: Docker manipulates iptables directly to publish container ports, which can **bypass ufw rules entirely** — a container port can be exposed to the world even though ufw shows it as "denied." This is a well-known, genuinely tricky production gotcha.
- **Order matters in iptables**: rules are evaluated top-to-bottom, first match wins — a broad `ACCEPT` rule placed before a specific `DROP` rule silently makes the `DROP` unreachable. nftables and firewalld abstract this somewhat but the underlying evaluation is still sequential.
- **Default DROP/REJECT policy**: always confirm the **default chain policy** (`iptables -L` shows `Chain INPUT (policy ACCEPT)` or `(policy DROP)`) — a firewall with an `ACCEPT` default policy and only `DROP` rules for specific things is inherently "default open," a common security misconfiguration.

## Hands-On Examples

**1. `ufw` — basic allow/deny (Ubuntu)**
```bash
$ sudo ufw allow 22/tcp
Rule added
$ sudo ufw allow from 10.0.1.0/24 to any port 8080
Rule added
$ sudo ufw default deny incoming
Default incoming policy changed to 'deny'
$ sudo ufw enable
Firewall is active and enabled on system startup

$ sudo ufw status verbose
Status: active
Default: deny (incoming), allow (outgoing)
To                         Action      From
22/tcp                     ALLOW IN    Anywhere
8080                       ALLOW IN    10.0.1.0/24
```

**2. `firewalld` — zones and the runtime vs permanent trap (RHEL)**
```bash
$ sudo firewall-cmd --get-active-zones
public
  interfaces: eth0

$ sudo firewall-cmd --zone=public --add-port=8080/tcp
success                              # applied NOW, but will vanish on reload/reboot

$ sudo firewall-cmd --zone=public --add-port=8080/tcp --permanent
success                              # persisted, but NOT active until reload

$ sudo firewall-cmd --reload
success

$ sudo firewall-cmd --zone=public --list-ports
8080/tcp
```

**3. `nftables` — a raw modern ruleset**
```bash
$ sudo nft list ruleset
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif "lo" accept
        tcp dport 22 accept
        tcp dport 443 accept
    }
}

$ sudo nft add rule inet filter input tcp dport 8080 accept
$ sudo nft list chain inet filter input | grep 8080
    tcp dport 8080 accept
```

**4. `iptables` — legacy syntax, still worth reading fluently**
```bash
$ sudo iptables -L -n -v --line-numbers
Chain INPUT (policy DROP 0 packets, 0 bytes)
num   pkts bytes target     prot opt in     out     source          destination
1        0     0 ACCEPT     tcp  --  *      *       0.0.0.0/0       0.0.0.0/0   tcp dpt:22
2      412 61.8K ACCEPT     tcp  --  *      *       10.0.1.0/24     0.0.0.0/0   tcp dpt:8080

$ sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT
$ sudo iptables-save > /etc/iptables/rules.v4   # persist (Debian/Ubuntu pattern)
```

**5. Diagnosing "port shows open in the app but connection is refused externally" — checking policy first**
```bash
$ ss -tlnp | grep 8080
tcp   LISTEN  0.0.0.0:8080   0.0.0.0:*   users:(("java",pid=2210))

$ curl -v http://10.0.1.5:8080/health --connect-timeout 3
* connect to 10.0.1.5 port 8080 failed: Connection timed out

$ sudo firewall-cmd --list-ports
# (empty — 8080 was never opened)

$ sudo firewall-cmd --add-port=8080/tcp --permanent && sudo firewall-cmd --reload
$ curl -sf http://10.0.1.5:8080/health && echo OK
OK
```
This is the classic pattern: app is listening (`ss` proves it), but the firewall is silently dropping inbound packets before they ever reach the socket — a **connection timeout**, not "connection refused," is the tell (refused = reached the host, nothing listening/RST; timeout = packet dropped somewhere in between).

**6. Docker bypassing ufw (real gotcha)**
```bash
$ sudo ufw status
Status: active
To                Action   From
22/tcp             ALLOW   Anywhere

$ docker run -d -p 6379:6379 redis:7
# Redis is now reachable from the INTERNET on 6379, despite ufw showing no rule for it —
# Docker inserted its own iptables DNAT/ACCEPT rules that ufw doesn't see or control.

$ sudo iptables -t nat -L DOCKER -n | head -3
Chain DOCKER (2 references)
target     prot opt source     destination
ACCEPT     tcp  --  0.0.0.0/0  0.0.0.0/0   tcp dpt:6379
```
Fix pattern: bind container ports to localhost only (`-p 127.0.0.1:6379:6379`) or configure Docker's `iptables: false` + manage rules explicitly, understanding Docker's default behavior injects its own rules ahead of ufw's chain.

## Practice Questions

1. Explain the actual relationship between iptables, nftables, firewalld, and ufw — which of these are "the firewall" at the kernel level, and which are management layers on top?
2. You run `firewall-cmd --add-port=8080/tcp --permanent` and the port still isn't reachable. What's the most likely mistake, and how do you fix it?
3. On Ubuntu, `ufw status` shows no rule for port 6379, yet Redis is reachable from the internet. What's likely happening, and how would you confirm it?
4. What's the practical difference between "connection refused" and "connection timed out" when a firewall is blocking a port, and which points to a DROP vs a REJECT policy?
5. Given `iptables -L` output with two rules — a broad `ACCEPT` above a specific `DROP` for the same traffic — which one wins, and why?
6. Explain firewalld zones (e.g., `public` vs `internal` vs `trusted`) — why does this concept not exist in ufw, and when would zones actually matter in a real deployment?
7. If you had to write a brand-new firewall ruleset today for a fresh RHEL 9 server and a fresh Ubuntu 24.04 server, which tool would you reach for on each, and why?
8. What does it mean that "iptables commands are often just a shim to nftables" on a modern distro — how would you check which is actually enforcing rules under the hood?
9. Write the ufw commands to allow SSH from anywhere, allow port 8080 only from the `10.0.1.0/24` subnet, and set the default incoming policy to deny.
10. A security audit finds `Chain INPUT (policy ACCEPT)` with only a handful of explicit DROP rules. Why is this a bad security posture, and what should the policy be instead?

## Real Interview Questions (Company-Attributed)

- "What is `iptables` in Linux?" — asked at *HCL*
- "How do you check firewall protection on a system?" — asked at *Akamai*

## Interview Key Points

- **The #1 thing interviewers check: do you understand these are layered, not competing** — nftables/iptables are kernel-level engines, firewalld/ufw are management layers on top, usually backed by nftables today.
- **The decision rule is a strong senior-level answer**: ufw for Ubuntu/Debian simplicity, firewalld for RHEL/zone-based enterprise setups, raw nftables for custom/performance-sensitive rules, iptables as a legacy-reading skill — state this explicitly rather than picking one tool as "the answer."
- **firewalld's runtime vs `--permanent` distinction** is probably the single most commonly-tested practical gotcha in this whole topic — always mention needing both (or a `--reload`) for a change that's both immediate and durable.
- **Docker silently manipulating iptables/nftables rules, bypassing ufw/firewalld** is a real, frequently-cited production gotcha worth raising proactively — shows hands-on incident experience, not just textbook knowledge.
- Connection **timeout vs refused** is the fast diagnostic signal for "is this a firewall DROP (timeout, silent) vs no listener/explicit REJECT (refused, fast fail)" — a concrete, testable distinction to have ready.
- Know that **nftables is the current kernel-native standard** (since ~3.13, and the enforced default on recent RHEL/Debian/Ubuntu) — don't present iptables as "the modern way," even though it's still extremely common to encounter.
- Rule **order/evaluation (first match wins, top-to-bottom)** and **default chain policy** (`ACCEPT` vs `DROP`) are fundamentals interviewers expect without prompting — a "default open with scattered DROPs" setup is a classic thing to flag as a misconfiguration.
- Be ready to explain **why container/Kubernetes environments complicate this picture** — kube-proxy and Docker manage iptables/nftables rules directly, which is why firewalld/ufw are frequently disabled entirely on container hosts rather than layered underneath.
