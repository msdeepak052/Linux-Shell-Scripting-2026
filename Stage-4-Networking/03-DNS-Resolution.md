# DNS Resolution: `/etc/resolv.conf`, `/etc/hosts`, `dig`, `nslookup`, `host`

How a hostname turns into an IP address on a Linux box, and the tools to diagnose it when that process breaks.

## Explanation

DNS failures are one of the most common "everything is broken" incidents in production, and they're deceptively easy to misdiagnose because the symptom (timeouts, connection errors) looks identical to a routing or firewall problem. Knowing the resolution order and having the right tools cuts diagnosis time from 20 minutes to 2.

### Resolution order on a Linux host

1. **`/etc/nsswitch.conf`** — defines the lookup order itself, typically `hosts: files dns` meaning: check `/etc/hosts` first, then DNS.
2. **`/etc/hosts`** — static hostname→IP mappings, checked first (by default). Great for local overrides, testing, or pinning a hostname without touching DNS.
3. **`/etc/resolv.conf`** — lists the DNS resolver(s) to query and search domains, used if `/etc/hosts` has no match.

```bash
$ cat /etc/hosts
127.0.0.1   localhost
10.0.1.20   db-primary.internal db-primary

$ cat /etc/resolv.conf
nameserver 10.0.0.2
search internal.example.com
options timeout:2 attempts:3
```
`search internal.example.com` means a bare lookup like `ping db-primary` gets `.internal.example.com` appended automatically if the unqualified name doesn't resolve directly — this explains a very common "works with FQDN but not short name" confusion (or vice versa, when a *wrong* search domain match shadows the one you wanted).

### The `systemd-resolved` complication (modern Ubuntu/Debian)

On most modern systemd-based distros, `/etc/resolv.conf` is often a **symlink** to a stub file managed by `systemd-resolved`, pointing to `127.0.0.53` — a local caching stub resolver, NOT the real upstream DNS server:
```bash
$ cat /etc/resolv.conf
nameserver 127.0.0.53
```
This trips people up constantly: they think the DNS server is `127.0.0.53` (it isn't — that's a local stub), and they need `resolvectl status` (or `systemd-resolve --status` on older systems) to see the actual upstream nameservers systemd-resolved is forwarding to.
```bash
$ resolvectl status | grep -A2 "Current DNS"
Current DNS Server: 10.0.0.2
DNS Servers: 10.0.0.2 8.8.8.8
```

### `dig` vs `nslookup` vs `host`

| Tool | Best for | Notes |
|---|---|---|
| **`dig`** | Deep diagnostics, scripting, scriptable/parseable output | Shows full response: answer, authority, additional sections, query time, flags. Industry-standard for real troubleshooting. |
| **`nslookup`** | Quick interactive lookup | Older, was deprecated-then-revived; less detail by default; behavior differs slightly across implementations. |
| **`host`** | Fast one-line lookup | Simplest output, good for quick scripts, not much diagnostic depth. |

### Which one should you actually use? (Decision rule)

| Situation | Tool |
|---|---|
| Real troubleshooting: TTL, which server answered, full record data, SOA/NS chasing | `dig` |
| Quick "does this resolve at all" sanity check | `host` |
| Habit / legacy familiarity, quick interactive check | `nslookup` (fine, just don't rely on it for scripting) |
| Scripting/automation (parseable, `+short`) | `dig +short` |

**Bottom line**: reach for `dig` as your default DNS diagnostic tool — it gives the full picture (which server answered, TTL, response flags) that `nslookup`/`host` hide; use `dig +short` when you just want the answer in a script.

### Common DNS record types you must recognize

- **A** — hostname → IPv4
- **AAAA** — hostname → IPv6
- **CNAME** — alias to another hostname (chains resolve until an A/AAAA is hit)
- **MX** — mail server priority/target
- **TXT** — arbitrary text (SPF, domain verification, etc.)
- **NS** — authoritative nameservers for a zone
- **SOA** — zone's authority record (serial, refresh/retry/expire timers, admin contact)
- **PTR** — reverse lookup (IP → hostname), used by `dig -x`

## Hands-On Examples

**1. Basic `dig` lookup and reading the output**
```bash
$ dig api.example.com

; <<>> DiG 9.18.1 <<>> api.example.com
;; ANSWER SECTION:
api.example.com.   287   IN   A   93.184.216.34

;; Query time: 24 msec
;; SERVER: 10.0.0.2#53(10.0.0.2)
;; WHEN: Sat Aug 08 14:20:01 UTC 2026
```
`287` is the TTL (seconds) remaining before this record must be re-fetched — useful when diagnosing "I updated DNS but it's still resolving the old IP" (stale cache waiting on TTL expiry).

**2. `dig +short` for scripting**
```bash
$ dig +short api.example.com
93.184.216.34

$ IP=$(dig +short db-primary.internal.example.com)
$ echo "Resolved to: $IP"
Resolved to: 10.0.1.20
```

**3. Tracing a CNAME chain**
```bash
$ dig cdn.example.com

;; ANSWER SECTION:
cdn.example.com.       300  IN  CNAME  d111111abcdef8.cloudfront.net.
d111111abcdef8.cloudfront.net. 60 IN A  13.35.19.4
```
The final A record is what actually gets connected to — CNAME chains resolving to unexpected infra (e.g., a decommissioned CDN) is a real-world outage pattern.

**4. Reverse lookup (PTR)**
```bash
$ dig -x 10.0.1.20 +short
db-primary.internal.example.com.
```

**5. Checking WHICH server answered, and forcing a specific resolver**
```bash
$ dig api.example.com @8.8.8.8
;; SERVER: 8.8.8.8#53(8.8.8.8)
;; ANSWER SECTION:
api.example.com.  300  IN  A  93.184.216.34
```
Querying `@8.8.8.8` directly (bypassing your local resolver/cache) is the standard way to check "is this a problem with my resolver, or is the record actually wrong upstream/publicly?"

**6. Diagnosing "works internally, fails from outside" — checking authoritative NS**
```bash
$ dig example.com NS +short
ns1.exampledns.com.
ns2.exampledns.com.

$ dig api.example.com @ns1.exampledns.com. +short
93.184.216.34
```
Querying the authoritative nameserver directly, bypassing all caching layers, confirms whether the record is actually correct at the source — isolates "DNS is wrong" from "DNS is cached/propagating."

**7. Real incident: `resolv.conf` misconfigured, resolution totally broken**
```bash
$ curl -v https://api.internal.example.com
* Could not resolve host: api.internal.example.com

$ cat /etc/resolv.conf
nameserver 127.0.0.53      # systemd-resolved stub

$ resolvectl status
Link 2 (eth0)
    Current DNS Server: 10.0.0.99      # WRONG — internal DNS server is 10.0.0.2, not .99
    DNS Servers: 10.0.0.99

$ dig api.internal.example.com @10.0.0.2 +short   # confirm the CORRECT server works
10.0.1.20

# fix: correct the DHCP-provided DNS or netplan/nmcli DNS override to 10.0.0.2, then:
$ sudo resolvectl flush-caches
$ dig api.internal.example.com +short
10.0.1.20
```

**8. Diagnosing a stale-cache "still resolves to the old IP after a DNS change"**
```bash
$ dig api.example.com +short
203.0.113.9        # old/decommissioned IP — DNS was changed 20 minutes ago

$ dig api.example.com +short @8.8.8.8   # bypass local cache, check public authoritative chain
198.51.100.44       # new IP — correct at the source

$ dig api.example.com | grep -A1 "ANSWER SECTION"
api.example.com.  3600  IN  A  203.0.113.9   # TTL was 1 HOUR — explains the lag
```
Root cause: DNS record TTL was 3600s (1 hour), so the old IP is still cached locally until it expires — not a DNS misconfiguration, just TTL propagation delay. This is a very common real "false alarm" pattern.

## Practice Questions

1. Walk through the exact order Linux resolves a hostname: which files/services are checked, in what sequence, and where does `/etc/nsswitch.conf` fit in?
2. Why does `/etc/resolv.conf` on a modern Ubuntu system often show `nameserver 127.0.0.53`, and how do you find the *actual* upstream DNS server being used?
3. `dig api.example.com` returns an old IP, but `dig api.example.com @8.8.8.8` returns the correct new one. What's happening, and what's your next diagnostic step?
4. Explain what a CNAME chain is, and why `dig` showing multiple records in the ANSWER SECTION for one query isn't necessarily an error.
5. What does the TTL value in a `dig` response tell you, and how does it explain "I updated the DNS record 5 minutes ago but it's still resolving to the old IP"?
6. What's the practical/diagnostic difference between `dig`, `nslookup`, and `host` — if you were troubleshooting a production DNS issue live, which would you reach for and why?
7. A host has a correct `/etc/resolv.conf` but `curl https://api.example.com` still fails with "could not resolve host." What are three things you'd check next?
8. How would you determine whether a DNS problem is happening in your local resolver/cache vs. being wrong at the authoritative source?
9. What's the purpose of the `search` directive in `/etc/resolv.conf`, and describe a scenario where it causes an unexpected/wrong hostname to resolve.
10. Given `dig -x 10.0.1.20`, what type of DNS record does this query, and what's it used for in a production troubleshooting context?

## Interview Key Points

- **`/etc/hosts` is checked before DNS by default** (per `/etc/nsswitch.conf`'s `hosts: files dns` order) — know this cold, it's a very common "why is this hostname resolving wrong despite correct DNS" trap (someone left a stale entry in `/etc/hosts`).
- **`127.0.0.53` in `/etc/resolv.conf` is a systemd-resolved stub, not the real DNS server** — a frequently-tested "gotcha" on modern Ubuntu/Debian; know `resolvectl status` as the way to see the actual upstream resolver.
- **TTL explains "still resolving old IP after a DNS change"** far more often than actual misconfiguration — always check the TTL before assuming something is broken.
- Always know how to **bypass local caching and query directly** (`dig @<server>` or `dig @<authoritative-ns>`) to isolate "my resolver/cache is wrong" from "the record itself is wrong at the source" — this is the core skill interviewers are probing for.
- `dig` is the professional default; `nslookup`/`host` are fine for quick checks but lack the detail (TTL, flags, which server answered, full sections) that real diagnosis needs.
- Know the common record types (A, AAAA, CNAME, MX, TXT, NS, SOA, PTR) and be able to say what each is for without hesitating.
- "DNS resolves fine but the app still can't connect" isolates the failure to Layer 4+ (port/firewall/app) — DNS troubleshooting is usually step one in a larger triage sequence, not the whole story (see the Troubleshooting-Tools file for the full ping→traceroute→curl→tcpdump sequence).
- `search` domain suffixes in `/etc/resolv.conf` can cause **wrong** hostnames to silently resolve (matching an unintended internal zone) — a subtle, senior-level gotcha worth mentioning proactively.
