# Reverse Proxy & Load Balancer Awareness: nginx, HAProxy

A platform engineer doesn't need to be a full-time nginx/HAProxy developer, but must understand what a reverse proxy actually does, why it sits where it does, and how to read/debug its config and logs under pressure.

## Explanation

**Reverse proxy vs forward proxy**: a forward proxy sits in front of *clients* (hides client identity from servers, e.g., corporate web proxy). A **reverse proxy** sits in front of *servers* (hides backend topology from clients) — clients think they're talking to one server; the proxy actually routes to one of many backends. Common jobs: TLS termination, load balancing, caching, request routing/rewriting, compression, rate limiting, and centralizing access logs.

**Load balancing algorithms**: `round-robin` (default, cycles evenly), `least_conn` (send to backend with fewest active connections — better for long-lived/uneven requests), `ip_hash`/`hash` (same client always to same backend — cheap session affinity without shared session storage), `weighted` (skew traffic by backend capacity), `random` (less common, used for very large backend pools).

**Health checks**: **passive** (mark a backend down after N failed requests observed in normal traffic — nginx OSS does this via `max_fails`/`fail_timeout`) vs **active** (proxy proactively polls a health endpoint on an interval, independent of real traffic — HAProxy and nginx Plus support this natively). Active checks catch a dying backend faster and don't require a real user request to fail first.

**nginx as reverse proxy**: `proxy_pass` directive forwards to an `upstream` block (a named pool of backends). Must explicitly forward headers that clients expect the backend to see (`proxy_set_header Host $host`, `X-Real-IP $remote_addr`, `X-Forwarded-For $proxy_add_x_forwarded_for`, `X-Forwarded-Proto $scheme`) — nginx does NOT do this automatically, a very common misconfiguration. `proxy_connect_timeout`/`proxy_read_timeout` govern how long nginx waits on the backend.

**HAProxy**: purpose-built L4/L7 load balancer, more feature-rich for LB-specific concerns (SSL, stickiness, sophisticated health checks, circuit-breaking-like behavior) than nginx, though nginx has closed much of the gap. Config structure: `frontend` (where clients connect, defines binds and ACL-based routing), `backend` (pool of servers + balance algorithm + health check config), `listen` (frontend+backend combined, simpler for basic setups). `mode http` vs `mode tcp` determines L7 vs L4 operation. Real-time stats available via the built-in stats page/socket (`stats socket`), which is a key operational differentiator vs nginx OSS.

**L4 vs L7 load balancing**: L4 (TCP-level) just forwards packets/connections based on IP:port, doesn't see HTTP — faster, protocol-agnostic, but can't route on URL path/headers/cookies. L7 (HTTP-aware) can route by path, host header, cookie, etc., terminate/re-encrypt TLS, and manipulate the request, at the cost of more CPU and being HTTP-specific.

**Sticky sessions**: needed when app state lives in-memory on a specific backend instance (not ideal, but common with legacy apps). Achieved via `ip_hash` (client IP-based, breaks if client IP changes, e.g., behind NAT/corporate proxy), or cookie-based affinity (HAProxy `cookie` directive, or nginx Plus `sticky`) which is more reliable. The better architectural fix is externalizing session state (Redis, etc.) so any backend can serve any request — worth mentioning as the "right" answer in interviews.

**Common failure modes**: 502 Bad Gateway (proxy couldn't get a valid response from backend — backend down, crashed, or connection refused), 504 Gateway Timeout (backend accepted the connection but didn't respond in time — slow query, deadlock, overload), 503 Service Unavailable (often from the proxy itself — no healthy backends, or rate-limit/circuit-breaker tripped).

## Hands-On Examples

**1. Minimal nginx reverse proxy with upstream pool**
```nginx
upstream app_backend {
    least_conn;
    server 10.0.1.10:8080 weight=3;
    server 10.0.1.11:8080 weight=1;
    server 10.0.1.12:8080 backup;   # only used if the others are down
}

server {
    listen 443 ssl;
    server_name api.example.com;

    location / {
        proxy_pass http://app_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 30s;
    }
}
```

**2. Diagnosing a 502 in nginx error log**
```bash
$ sudo tail -n 5 /var/log/nginx/error.log
2026/08/08 10:41:02 [error] 1421#1421: *892 connect() failed (111: Connection refused)
  while connecting to upstream, client: 203.0.113.9, server: api.example.com,
  request: "GET /orders HTTP/1.1", upstream: "http://10.0.1.10:8080/orders"
# "Connection refused" = nothing is listening on 10.0.1.10:8080 — app crashed or not started

$ ssh 10.0.1.10 "systemctl status app"
● app.service - Application Server
   Active: failed (Result: exit-code) since Thu 2026-08-08 10:40:55 UTC
```

**3. nginx passive health check config (mark backend down after failures)**
```nginx
upstream app_backend {
    server 10.0.1.10:8080 max_fails=3 fail_timeout=30s;
    server 10.0.1.11:8080 max_fails=3 fail_timeout=30s;
}
# after 3 failed proxy attempts within 30s, nginx stops sending traffic to that
# server for the next 30s, then retries it (passive — driven by real requests)
```

**4. HAProxy config with active health checks and stats page**
```
frontend web_front
    bind *:443 ssl crt /etc/haproxy/certs/example.pem
    mode http
    default_backend web_back

backend web_back
    mode http
    balance roundrobin
    option httpchk GET /healthz
    http-check expect status 200
    server web1 10.0.1.10:8080 check inter 5s fall 3 rise 2
    server web2 10.0.1.11:8080 check inter 5s fall 3 rise 2

listen stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 10s
```

**5. Reading HAProxy stats to spot a flapping backend**
```bash
$ curl -s http://localhost:8404/stats\;csv | grep web_back | cut -d, -f1,2,18
web_back,web1,UP
web_back,web2,DOWN
# web2 is currently failing health checks — check its /healthz endpoint directly
$ curl -sw "%{http_code}\n" -o /dev/null http://10.0.1.11:8080/healthz
503
```

**6. Reproducing "backend sees wrong client IP" misconfiguration**
```bash
# app logs on backend show the PROXY's IP for every request instead of the real client
$ tail /var/log/app/access.log
10.0.1.5 - - [08/Aug/2026:10:00:00] "GET /login HTTP/1.1" 200
10.0.1.5 - - [08/Aug/2026:10:00:01] "GET /login HTTP/1.1" 200
# fix: nginx config was missing proxy_set_header X-Forwarded-For, and app wasn't
# configured to trust/read it anyway — two separate things to check
```

**7. Testing L7 path-based routing**
```bash
$ curl -s https://api.example.com/v1/users | jq .service
"users-service"
$ curl -s https://api.example.com/v1/orders | jq .service
"orders-service"
# nginx location blocks or HAProxy ACLs routed each path prefix to a different upstream
```
```nginx
location /v1/users  { proxy_pass http://users_backend; }
location /v1/orders { proxy_pass http://orders_backend; }
```

**8. Sticky sessions via cookie in HAProxy**
```
backend web_back
    balance roundrobin
    cookie SERVERID insert indirect nocache
    server web1 10.0.1.10:8080 check cookie web1
    server web2 10.0.1.11:8080 check cookie web2
```
```bash
$ curl -i https://app.example.com/login
Set-Cookie: SERVERID=web1; path=/
# subsequent requests with this cookie always land on web1, regardless of round-robin
```

## Practice Questions

1. What's the practical difference between a forward proxy and a reverse proxy, and where does each sit in the request path?
2. A backend service crashes. What HTTP status code does the reverse proxy typically return to clients, and how does that differ from the code returned if the backend is up but hangs indefinitely on a slow query?
3. Explain the difference between passive and active health checks. Why might active checks catch an outage faster, and what's the tradeoff (extra load on backends, more moving parts)?
4. Users report that your application is logging every request as coming from the same IP address (the proxy's). What's misconfigured, and what two things need fixing (proxy side and app side)?
5. When would you choose `least_conn` over `round_robin` for load balancing? Give a concrete workload example where round-robin would perform badly.
6. What is sticky/session affinity, why is `ip_hash` an imperfect solution for it, and what's the architecturally "better" fix that avoids needing affinity at all?
7. Explain the difference between L4 and L7 load balancing. Give an example of a routing decision that's only possible at L7.
8. You need to route `/api/*` to one backend pool and `/static/*` to another, both behind the same public hostname/TLS cert. How would you configure this in nginx?
9. HAProxy's stats page shows a backend server as `DOWN`. Walk through your troubleshooting steps to determine whether it's a real outage or a health-check misconfiguration.
10. Why would a platform team choose HAProxy over nginx (or vice versa) for a given load-balancing use case? Name at least one concrete differentiator (e.g., stats/observability, TCP mode, config flexibility).

## Interview Key Points

- Be crisp on the **forward vs reverse proxy** distinction and where each sits — a very common warm-up question that separates candidates with real experience from those reciting definitions.
- Know the **502 vs 503 vs 504 distinction cold**: 502 = proxy got a bad/no response from backend (backend down/refused), 504 = backend accepted but didn't respond in time (slow/hung), 503 = proxy itself has no healthy backend or is rate-limiting/circuit-breaking. This maps directly to different root causes and is asked constantly.
- The **"forgot to set X-Forwarded-For / X-Real-IP / Host headers"** misconfiguration is a classic real-world gotcha (app logs show proxy IP for every client, rate-limiting/geo-IP breaks) — mention that nginx does NOT forward these automatically by default.
- Passive vs active health checks: know which nginx OSS supports (passive, via `max_fails`/`fail_timeout`) vs what requires nginx Plus or HAProxy (active `option httpchk`) — a nuance that shows real config experience.
- Sticky sessions are a **known anti-pattern to call out**: they work but couple client to a specific backend, defeating elastic scaling/graceful backend replacement — the senior answer names externalized session state (Redis/memcached) as the preferred fix, with sticky sessions as the pragmatic stopgap.
- L4 vs L7 tradeoff: L4 is faster/simpler/protocol-agnostic but blind to HTTP content (can't route by path/host/cookie); L7 enables smart routing and TLS termination at the cost of more CPU/complexity — know when each is appropriate.
- HAProxy's built-in stats page/socket is a real operational differentiator versus nginx OSS (which needs third-party modules/Plus for equivalent visibility) — worth knowing as a concrete "why HAProxy" answer.
- Weighted load balancing (`weight=`) is the practical answer to "how do you send more traffic to a bigger/newer instance during a mixed-capacity rollout" — a good scenario question to be ready for.
