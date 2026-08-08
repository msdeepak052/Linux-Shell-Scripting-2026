# Network Troubleshooting: ping, traceroute/mtr, curl, wget, tcpdump, nc/telnet

When "it's not working," a structured toolset for isolating whether the problem is reachability, routing, DNS, TLS, the app layer, or somewhere in between is what separates fast triage from guessing.

## Explanation

**`ping`** — ICMP echo request/reply, tests basic L3 reachability and round-trip latency. Doesn't confirm a *service* is up (ICMP can be blocked while TCP works, and vice versa). Key flags: `-c N` (count), `-i` (interval), `-W` (timeout), `-s` (packet size, useful for MTU testing).

**`traceroute` / `mtr`** — map the L3 path hop-by-hop by sending packets with increasing TTL and capturing the "TTL exceeded" ICMP replies from each router. `traceroute` gives a one-shot snapshot; `mtr` (My TraceRoute) combines ping+traceroute continuously, showing per-hop packet loss and jitter over time — much better for spotting an intermittently lossy hop. Caveat: intermediate hops may rate-limit or block ICMP, showing as `* * *` — doesn't necessarily mean the path is broken, just that hop doesn't reply.

**`curl`** — the Swiss-army knife for L7 (HTTP/HTTPS/FTP/etc.) testing. Key flags: `-v` (verbose, shows request/response headers + TLS handshake), `-I` (HEAD only), `-o`/`-O` (save output), `-w` (custom output format, e.g., timing breakdown), `-k` (skip TLS verify — debugging only), `-H` (custom header), `-X` (method), `--resolve` (override DNS for a host, test a specific backend before DNS cutover), `-s -o /dev/null -w "%{http_code}"` (scripting-friendly status-code-only check).

**`wget`** — simpler recursive-download-oriented alternative to curl; strengths are resumable downloads (`-c`), mirroring (`--mirror`), and being present on more minimal images historically (though curl is now near-universal too).

**`tcpdump`** — packet capture at L2/L3/L4, the ground-truth tool when app-layer tools disagree with reality. Key flags: `-i` (interface, `any` for all), `-n` (don't resolve hostnames — faster, avoids DNS noise), `-nn` (also don't resolve port names), `-w file.pcap` (write for later analysis in Wireshark), `-c N` (count), filter expressions (`host`, `port`, `net`, `tcp`, `udp`, `and`/`or`). Common filter: `tcp port 443 and host 10.0.1.5`. Requires root/`CAP_NET_RAW`.

**`nc` (netcat) / `ncat`** — raw TCP/UDP swiss-army knife. Test if a port is open (`nc -zv host port`), act as a quick listener (`nc -l port`), or pipe data between two ends. `-z` = scan mode (no data sent), `-v` verbose, `-u` UDP, `-w` timeout. Useful when `telnet`/app clients aren't installed.

**`telnet`** — legacy but still handy purely as a raw TCP connect test to a port (`telnet host port`) — if it connects, TCP-level reachability is confirmed; doesn't speak TLS so it's for plaintext protocol probing (or just confirming the handshake, then Ctrl+] to quit) — largely superseded by `nc -zv` and `curl` but interviewers still ask about it as a baseline reachability check.

## Hands-On Examples

**1. Basic reachability + latency check**
```bash
$ ping -c 4 8.8.8.8
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
64 bytes from 8.8.8.8: icmp_seq=1 ttl=117 time=12.4 ms
64 bytes from 8.8.8.8: icmp_seq=2 ttl=117 time=11.9 ms
64 bytes from 8.8.8.8: icmp_seq=3 ttl=117 time=12.1 ms
64 bytes from 8.8.8.8: icmp_seq=4 ttl=117 time=12.6 ms

--- 8.8.8.8 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3005ms
rtt min/avg/max/mdev = 11.9/12.25/12.6/0.26 ms
```

**2. mtr for spotting an intermittently lossy hop**
```bash
$ mtr -rwc 20 api.internal.example.com
Start: 2026-08-08T10:15:00
HOST: gateway.local                Loss%   Snt   Last   Avg  Best  Wrst StDev
  1. 10.0.0.1                       0.0%    20    0.5   0.6   0.4   1.2   0.2
  2. 10.10.1.1                      0.0%    20    1.1   1.3   1.0   2.1   0.3
  3. core-rtr-3.isp.net            35.0%    20    8.2  22.4   8.0  95.3  25.1   <- lossy hop
  4. 172.16.5.1                     0.0%    20   14.5  15.0  14.0  18.2   1.1
  5. api-internal (10.0.5.20)       0.0%    20   15.1  15.6  14.9  19.0   1.3
```
Hop 3 shows loss, but hop 4/5 are clean — often that loss is cosmetic rate-limiting on that router and not a real problem, since traffic still arrives at the destination; correlate with actual end-to-end loss before escalating.

**3. curl with timing breakdown — isolating DNS/TCP/TLS/server latency**
```bash
$ curl -o /dev/null -s -w "dns:%{time_namelookup} connect:%{time_connect} tls:%{time_appconnect} ttfb:%{time_starttransfer} total:%{time_total}\n" https://api.example.com/health
dns:0.045 connect:0.058 tls:0.112 ttfb:0.198 total:0.199
```

**4. curl verbose to inspect the TLS handshake and headers**
```bash
$ curl -vI https://api.example.com
* Connected to api.example.com (203.0.113.50) port 443
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
* Server certificate: expire date Nov 12 23:59:59 2026 GMT
> HEAD / HTTP/1.1
> Host: api.example.com
< HTTP/1.1 200 OK
< server: nginx/1.24.0
< content-type: application/json
```

**5. curl --resolve — test a specific backend before a DNS cutover**
```bash
$ curl --resolve api.example.com:443:10.0.9.30 https://api.example.com/health
{"status":"ok","backend":"canary-v2"}
# confirms the new backend responds correctly BEFORE flipping DNS for everyone
```

**6. tcpdump to confirm SYN packets are actually leaving / arriving**
```bash
$ sudo tcpdump -i eth0 -nn 'tcp port 443 and host 10.0.1.5'
10:22:01.113221 IP 10.0.0.5.51422 > 10.0.1.5.443: Flags [S], seq 123456, win 64240
10:22:01.113890 IP 10.0.1.5.443 > 10.0.0.5.51422: Flags [S.], seq 987654, ack 123457
10:22:01.114001 IP 10.0.0.5.51422 > 10.0.1.5.443: Flags [.], ack 987655
# clean 3-way handshake — TCP-level connectivity confirmed, issue is likely app-layer

$ sudo tcpdump -i eth0 -nn 'tcp port 443 and host 10.0.1.5'
10:23:15.001122 IP 10.0.0.5.51500 > 10.0.1.5.443: Flags [S], seq 555, win 64240
10:23:16.003001 IP 10.0.0.5.51500 > 10.0.1.5.443: Flags [S], seq 555, win 64240   # retransmit
10:23:18.007001 IP 10.0.0.5.51500 > 10.0.1.5.443: Flags [S], seq 555, win 64240   # retransmit
# no SYN-ACK ever comes back — points to firewall drop or host down, not app issue
```

**7. nc for a quick port-open check without a full client**
```bash
$ nc -zv 10.0.1.5 5432
Connection to 10.0.1.5 5432 port [tcp/postgresql] succeeded!

$ nc -zv 10.0.1.5 5432 -w 3
nc: connect to 10.0.1.5 port 5432 (tcp) timed out: Operation now in progress
# TCP-level: port is filtered/closed, not an app-level auth or query problem
```

**8. telnet as a manual protocol probe (plaintext only)**
```bash
$ telnet mail.example.com 25
Trying 203.0.113.80...
Connected to mail.example.com.
Escape character is '^]'.
220 mail.example.com ESMTP Postfix
EHLO test
250-mail.example.com
^]
telnet> quit
Connection closed.
```

## Practice Questions

1. A `ping` to a host succeeds but `curl` to it times out. Walk through your triage steps — what does this combination of symptoms tell you, and what layers does each tool actually test?
2. Explain why `traceroute`/`mtr` showing `* * *` or high loss% at an intermediate hop doesn't necessarily mean there's a real problem. How would you confirm whether it matters?
3. What's the difference between `mtr` and `traceroute`, and why would you reach for `mtr` specifically when debugging an intermittent latency complaint?
4. Using `curl -w`, how would you break down where time is being spent in a slow HTTPS request (DNS vs TCP connect vs TLS handshake vs server processing vs transfer)?
5. You need to test a new backend server's behavior for a specific hostname before changing DNS in production. What curl flag lets you do this safely, and how does it work?
6. A `tcpdump` capture shows repeated SYN packets with no SYN-ACK response. What does that tell you, and what are 2-3 likely root causes?
7. When would you use `nc -zv` instead of `curl` or `telnet` to check connectivity, and what's the practical difference between what each confirms?
8. Explain the difference between what a successful `ping` proves versus what a successful `nc -zv host 443` proves versus what a successful `curl https://host` proves — map each to an OSI/TCP-IP layer.
9. How would you use `tcpdump` to capture traffic to a pcap file for offline analysis in Wireshark, and what filter would you use to limit it to HTTPS traffic to/from a specific host?
10. A service is unreachable. Describe your troubleshooting order of operations from L1 up through L7 (link/interface up? routing? DNS? TCP port open? TLS handshake OK? HTTP response correct?) and which single command you'd use to check each layer.

## Real Interview Questions (Company-Attributed)

- "If you're unable to access a Linux machine, what would you do?" — asked at *Akamai*
- "You're locked out via SSH with no root access — how do you recover?" — asked at *an unnamed company (via community-sourced interview notes)*
- "A user is unable to get SSH access — what troubleshooting steps would you perform?" — asked at *Qentelli Solutions*
- "Write a script to check if an external API is reachable before making a request." — asked at *Turning*
- "Explain the use of `nc` and `mtr`." — asked at *Sigmoid* (part of a rapid-fire "explain these Linux commands" interview round)

## Interview Key Points

- Map each tool to the **OSI/TCP-IP layer it actually tests** — this is the core skill being probed: ping (L3/ICMP), nc/telnet (L4/TCP connect), curl (L7/application + TLS), tcpdump (any layer, ground truth). Confusing "ping works so the service should be reachable" is a classic red flag answer.
- Know that **ICMP being blocked doesn't mean TCP/the service is down**, and vice versa — many networks/firewalls block ping but allow the actual service port; don't conflate the two.
- `mtr` > one-shot `traceroute` for intermittent issues because it's continuous and shows per-hop loss/jitter statistically, not a single snapshot — mention this distinction explicitly.
- Intermediate hop loss/timeouts in traceroute are frequently **cosmetic** (router deprioritizes/rate-limits ICMP TTL-exceeded generation) — a senior answer explicitly separates "this hop looks lossy" from "there's an actual problem," and checks end-to-end loss to confirm.
- `curl -w` timing breakdown (`time_namelookup`, `time_connect`, `time_appconnect`, `time_starttransfer`, `time_total`) is a go-to for isolating DNS vs TCP vs TLS vs server-processing latency — know the field names or at least the concept.
- `tcpdump` is the tiebreaker when tools disagree or when you need proof — SYN with no SYN-ACK means packets aren't reaching the service (firewall/routing/host-down), SYN-ACK received but app hangs means it's an application-layer problem, not network.
- Know `nc -zv` as the lightweight "is this port even open" check, useful when you don't want to trigger a full app-layer handshake or don't have the real client installed.
- `-k`/`--insecure` on curl (skip TLS verification) is a debugging-only flag — flag it as something you'd never leave in production tooling/scripts.
