# TLS/Certificates Basics: OpenSSL Commands (Generate Keys/Certs, Verify, Inspect)

Every HTTPS endpoint, internal service mesh, and mutual-TLS setup rests on the same handful of `openssl` commands — the tool every platform engineer eventually has to run by hand at 2am when a cert has expired.

## Explanation

**The core objects**: a **private key** (kept secret, proves identity by being able to sign/decrypt), a **CSR** (Certificate Signing Request — a public key plus identity info, sent to a CA to be signed), and a **certificate** (the CA's signed statement: "this public key belongs to this identity, until this expiry date"). A **self-signed certificate** skips the CA entirely — the cert signs itself — which is fine for internal/dev/test use but will always show as untrusted to a normal browser/client because there's no chain back to a trusted root CA.

**Key generation** (`openssl genpkey` — the modern unified command, or the older algorithm-specific `openssl genrsa`): produces the private key file. **RSA** (commonly 2048 or 4096-bit) is the traditional default; **ECDSA** (e.g., P-256) and **Ed25519** are modern alternatives offering equivalent security with smaller keys and faster operations — increasingly the default for new deployments, though RSA remains near-universal for compatibility with older clients/systems.

**CSR generation** (`openssl req -new`): bundles the public key (derived from the private key) with identity fields — Common Name (CN, historically the hostname, now largely superseded by SAN), Organization, Country — into a request. In modern TLS, the **Subject Alternative Name (SAN)** field is what browsers and clients actually validate against the hostname, not the CN; a cert without the right SAN entries will fail validation in current browsers even if the CN "looks right." This is a very common real-world gotcha when generating internal certs by hand.

**Self-signing** (`openssl req -x509 ...`): combines CSR generation and self-signing into one step — the fast path for internal/dev certs. For anything that needs to be trusted by real clients, the CSR instead goes to a CA (public, like Let's Encrypt, or an internal/private CA) which signs it and returns the actual certificate.

**Inspecting a cert** (`openssl x509 -text -noout`): decodes the certificate's fields — issuer, subject, SAN, validity dates, public key, signature algorithm — essential for debugging "why doesn't this cert work" without guessing.

**Verifying a cert against a CA chain** (`openssl verify`): confirms a cert was actually signed by a trusted CA and the chain is complete/unexpired — distinct from *inspecting* a cert's contents; a cert can be perfectly well-formed and still fail verification (expired, wrong CA, incomplete chain).

**Checking a live server's presented cert** (`openssl s_client -connect host:443`): connects like a TLS client would and dumps the actual certificate chain the server sends — the go-to command for diagnosing "the browser says this site's cert is invalid" in production, because it shows you exactly what the server is presenting, which might differ from what you expect (misconfigured chain, wrong cert bound to the vhost/SNI, expired intermediate).

**Verifying a key matches a cert**: a private key and a certificate must correspond to the same key pair to work together (e.g., after a server migration where files got mixed up). The standard trick is comparing the **modulus** (RSA) or comparing derived public keys — if the hashes match, they're a pair.

### Which one should you actually use? (Decision rule)

| Scenario | Use | Why |
|---|---|---|
| Internal service, dev/test environment, mTLS between your own services | Self-signed cert, or better, an internal/private CA signing internal certs | No need for public trust; a private CA lets you centrally revoke/rotate without touching public CAs |
| Public-facing website/API | Certificate from a public CA (Let's Encrypt via ACME/certbot, or a commercial CA) | Browsers/clients need a trust chain to a root CA already in their trust store |
| Key algorithm choice for a new cert with no legacy constraint | ECDSA P-256 or Ed25519-based cert (where the CA/tooling supports it) | Smaller, faster handshakes, equivalent or better security than RSA-2048 at much less computational cost |
| Key algorithm choice where broad legacy client compatibility is required | RSA 2048 (or 4096 for extra margin) | Still the most universally supported option across old clients/libraries |

**Bottom line: reach for a private CA (or your cloud provider's internal CA service) for internal traffic instead of ad-hoc self-signed certs per-service once you have more than a couple of endpoints — self-signing directly doesn't scale operationally (no central revocation, manual trust distribution to every client) even though it's the fastest way to get a quick working cert for a single test.**

## Hands-On Examples

**1. Generating a modern private key**
```bash
$ openssl genpkey -algorithm RSA -out server.key -pkeyopt rsa_keygen_bits:2048
$ openssl rsa -in server.key -check -noout
RSA key ok
```

**2. Generating a CSR with a proper SAN (the modern, correct way)**
```bash
$ openssl req -new -key server.key -out server.csr \
    -subj "/C=US/O=MyCompany/CN=api.internal.mycompany.com" \
    -addext "subjectAltName=DNS:api.internal.mycompany.com,DNS:api,IP:10.0.1.15"
$ openssl req -in server.csr -text -noout | grep -A1 "Subject Alternative Name"
            X509v3 Subject Alternative Name:
                DNS:api.internal.mycompany.com, DNS:api, IP Address:10.0.1.15
```

**3. Self-signing a quick internal/dev certificate (CSR + signing in one step)**
```bash
$ openssl req -x509 -newkey rsa:2048 -keyout dev.key -out dev.crt -days 365 -nodes \
    -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
$ ls -l dev.key dev.crt
-rw------- 1 deepak deepak 1704 Aug  8 10:02 dev.key
-rw-r--r-- 1 deepak deepak 1216 Aug  8 10:02 dev.crt
```
`-nodes` ("no DES") means the private key is stored unencrypted — fine for a throwaway dev cert, never for a production key that will sit on disk long-term.

**4. Inspecting a certificate's contents**
```bash
$ openssl x509 -in dev.crt -text -noout
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number: 78:3a:9f:12:...
        Signature Algorithm: sha256WithRSAEncryption
        Issuer: CN=localhost
        Validity
            Not Before: Aug  8 10:02:11 2026 GMT
            Not After : Aug  8 10:02:11 2027 GMT
        Subject: CN=localhost
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                RSA Public-Key: (2048 bit)
        X509v3 extensions:
            X509v3 Subject Alternative Name:
                DNS:localhost, IP Address:127.0.0.1
```

**5. Quick expiry check — the single most common on-call use of openssl**
```bash
$ openssl x509 -in /etc/ssl/certs/api-prod.crt -noout -enddate
notAfter=Sep 15 23:59:59 2026 GMT

$ openssl x509 -in /etc/ssl/certs/api-prod.crt -noout -checkend 604800
Certificate will not expire
```
`-checkend 604800` (seconds = 7 days) returns non-zero if the cert will expire within that window — the exact check a monitoring script/cron job should run to alert before an outage, not after.

**6. Verifying a private key matches its certificate (post-migration sanity check)**
```bash
$ openssl x509 -in dev.crt -noout -modulus | openssl md5
(stdin)= 9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c

$ openssl rsa -in dev.key -noout -modulus | openssl md5
(stdin)= 9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c
```
Matching hashes confirm this key and this cert belong together — critical to check after copying files between servers or restoring from backup, where it's easy to end up with a mismatched pair.

**7. Diagnosing a live server's presented cert — the real production debugging move**
```bash
$ echo | openssl s_client -connect api.mycompany.com:443 -servername api.mycompany.com 2>/dev/null | openssl x509 -noout -subject -issuer -dates
subject=CN=api.mycompany.com
issuer=C=US, O=Let's Encrypt, CN=R11
notBefore=Jun 10 08:00:00 2026 GMT
notAfter=Sep  8 08:00:00 2026 GMT
```
`-servername` sets SNI — without it, on a server hosting multiple TLS vhosts, you might get the wrong (default) certificate back and misdiagnose the problem entirely.

**8. Verifying a certificate chain (self-signed CA scenario, e.g. internal PKI)**
```bash
$ openssl verify -CAfile internal-ca.crt api-internal.crt
api-internal.crt: OK

$ openssl verify -CAfile internal-ca.crt expired-cert.crt
CN = old-service.internal
error 10 at 0 depth lookup: certificate has expired
error api-internal.crt: verification failed
```
This distinguishes a well-formed-but-expired/untrusted cert from a genuinely broken one — `openssl x509 -text` would show the same expired cert as "syntactically fine," but `verify` is what actually tells you whether a client would trust it.

## Practice Questions

1. What's the actual difference between a private key, a CSR, and a certificate — and why can't you skip straight from key to certificate without a CA (or self-signing) in between?
2. Why does a certificate's Subject Alternative Name (SAN) matter more than its Common Name (CN) for modern TLS validation? What happens if a cert has the "right" CN but no matching SAN entry?
3. A monitoring script needs to alert 14 days before any production certificate expires. Write the `openssl` command that would power that check, and explain what its exit code means.
4. You inherit a server with `server.key` and `server.crt` files that supposedly belong together, but TLS handshakes are failing. What two commands would you run to confirm whether the key actually matches the cert?
5. Explain the difference between `openssl x509 -text -noout` and `openssl verify` — a cert can pass one and fail the other; describe a scenario where that happens.
6. Why would you use `openssl s_client -connect host:443 -servername host` instead of just checking the local `.crt` file on disk when debugging a "browser says invalid certificate" report?
7. What's the security implication of generating a private key with `-nodes` (unencrypted)? When is that an acceptable trade-off, and when is it not?
8. Explain why, for two internal services doing mTLS to each other, a self-signed cert on each side quickly becomes an operational headache as the number of services grows — what's the better approach at scale?
9. What's the practical trade-off between RSA-2048 and ECDSA/Ed25519 keys for a new certificate, assuming your tooling supports both?
10. Given `openssl verify -CAfile ca.crt cert.crt` returns `error 10: certificate has expired`, what's actually wrong, and is the certificate's cryptographic content otherwise still valid/trustworthy?

## Interview Key Points

- **SAN over CN is the modern reality** — browsers/clients ignore CN for hostname validation now; generating internal certs without proper SAN entries is one of the most common real-world "why doesn't this cert work" mistakes, and naming this unprompted signals current knowledge.
- **Inspecting a cert's contents (`x509 -text`) is NOT the same as verifying trust (`verify`)** — a cert can be well-formed and readable while still being expired, self-signed-and-untrusted, or missing from the chain; interviewers use this distinction to separate candidates who've only ever "looked at" a cert from those who've actually debugged trust failures.
- **`openssl s_client -connect ... -servername ...` is the real production debugging tool** — it shows what the server actually presents over the wire (accounting for SNI/vhost routing), which can differ from what you'd expect just reading a local file; always mention `-servername` explicitly, its omission is a common mistake that leads to misdiagnosis on multi-cert servers.
- **`-checkend` is the correct primitive for expiry monitoring**, not manually parsing `-enddate` output and diffing dates yourself — know this exists as the "right tool for the job" answer.
- **Comparing modulus hashes (or public key hashes) is the standard way to verify a key/cert pair match** — a real, common task after cert migrations, backups, or handoffs between teams.
- **Self-signed certs don't scale as an internal PKI strategy** — know to recommend a private/internal CA (or a managed service like AWS Private CA / step-ca / Vault PKI) once you're past a handful of internal services, for centralized issuance and revocation.
- **RSA vs ECDSA/Ed25519 is a real, current trade-off** — smaller/faster modern algorithms vs. maximum legacy compatibility; know both sides rather than defaulting to "RSA because that's what I've always used."
- **`-nodes` (unencrypted private key) is fine for throwaway dev/test certs, a real risk for anything long-lived in production** — tie this back to the secrets-handling principle of not leaving sensitive key material unprotected at rest.
