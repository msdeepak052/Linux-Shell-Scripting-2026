# SSH: Key Auth, ssh-agent, Config, Tunneling, scp/rsync

SSH is the backbone of remote Linux administration — key-based auth, agent forwarding, tunneling, and file transfer are daily-driver skills for any platform engineer.

## Explanation

**Key-based auth flow**: client generates a keypair (`ssh-keygen`), the **public** key is placed in the server's `~/.ssh/authorized_keys`, the **private** key stays on the client (never copied anywhere). On connect, the server challenges the client to prove possession of the private key (sign a nonce) — the private key itself is never transmitted. Permissions matter: `~/.ssh` must be `700`, `authorized_keys` and private keys `600` — sshd silently refuses to use files that are group/world-writable.

**Key types**: `ed25519` (modern default, fast, small, secure) preferred over `rsa` (still common for legacy compat, use 4096-bit if forced to use it) over `ecdsa`/`dsa` (avoid, legacy/weak).

**`ssh-agent`**: a background process that holds decrypted private keys in memory so you don't retype a passphrase on every connection. `eval $(ssh-agent)` starts it and exports `SSH_AUTH_SOCK`/`SSH_AGENT_PID`; `ssh-add` loads a key into it; `ssh-add -l` lists loaded keys; `ssh-add -D` flushes all. **Agent forwarding** (`ssh -A` or `ForwardAgent yes`) lets a remote host use your local agent's keys to hop further (e.g., jump host → internal host) without copying private keys onto the jump host — but forwarding to an untrusted host is a security risk since root on that host can potentially use your agent socket while you're connected.

**`~/.ssh/config`**: per-host client configuration, avoids repeating long `ssh` command lines. Key directives: `Host` (alias/pattern), `HostName`, `User`, `Port`, `IdentityFile`, `ProxyJump` (bastion hosting, replaces old `ProxyCommand nc %h %p`), `ForwardAgent`, `StrictHostKeyChecking`, `ServerAliveInterval`/`ServerAliveCountMax` (keepalive to prevent idle disconnects/NAT timeouts).

**Tunneling / port forwarding**:
- `-L local_port:dest_host:dest_port` — **local** forward: traffic to your local port is sent through the tunnel to `dest_host:dest_port` as seen from the remote server. Use case: reach a DB that's only reachable from the remote box.
- `-R remote_port:dest_host:dest_port` — **remote** forward: traffic hitting the remote server's port is sent back through the tunnel to a destination reachable from your local machine. Use case: expose your local dev server to a remote host, or NAT traversal.
- `-D local_port` — **dynamic** forward: turns SSH into a SOCKS proxy on `local_port`; all traffic routed through the proxy egresses via the remote host. Use case: browse as if you were on the remote network.
- `-N` — don't execute a remote command (tunnel only); `-f` — background after auth; `-g` — allow remote hosts to connect to forwarded ports (not just localhost).

**`scp`**: simple file copy over SSH, syntax `scp src dest` where either side can be `user@host:path`. `-r` recursive, `-P` port (capital, unlike `ssh -p`), `-p` preserve mode/times. Being deprecated in favor of `sftp`/`rsync` due to protocol limitations (no resume, weaker path handling), but still ubiquitous.

**`rsync`**: delta-transfer tool — only sends changed blocks, supports resuming, preserving permissions, deletion sync, and exclusion. Typically run over SSH with `-e ssh`. Key flags: `-a` (archive = recursive + preserve perms/times/symlinks/owner/group), `-v` verbose, `-z` compress in transit, `-P` (progress + partial/resume), `--delete` (mirror mode, remove files on dest not in src — dangerous, always dry-run first with `-n`), `--exclude`, `-n`/`--dry-run`.

## Hands-On Examples

**1. Generate an ed25519 keypair and deploy it**
```bash
$ ssh-keygen -t ed25519 -C "deepak@laptop-prod-access" -f ~/.ssh/id_ed25519_prod
Generating public/private ed25519 key pair.
Enter passphrase (empty for no passphrase): 
Your identification has been saved in /home/deepak/.ssh/id_ed25519_prod
Your public key has been saved in /home/deepak/.ssh/id_ed25519_prod.pub

$ ssh-copy-id -i ~/.ssh/id_ed25519_prod.pub deploy@10.0.1.15
Number of key(s) added: 1
$ ssh -i ~/.ssh/id_ed25519_prod deploy@10.0.1.15 whoami
deploy
```

**2. ssh-agent: load a passphrase-protected key once per session**
```bash
$ eval $(ssh-agent -s)
Agent pid 24831
$ ssh-add ~/.ssh/id_ed25519_prod
Enter passphrase for /home/deepak/.ssh/id_ed25519_prod: 
Identity added: /home/deepak/.ssh/id_ed25519_prod (deepak@laptop-prod-access)
$ ssh-add -l
256 SHA256:9fK3...abcd deepak@laptop-prod-access (ED25519)
$ ssh deploy@10.0.1.15   # no passphrase prompt now — agent handles it
```

**3. `~/.ssh/config` for a bastion-hopped internal host**
```bash
$ cat ~/.ssh/config
Host bastion
    HostName 203.0.113.10
    User ops
    IdentityFile ~/.ssh/id_ed25519_prod
    ServerAliveInterval 60
    ServerAliveCountMax 3

Host internal-db
    HostName 10.0.5.20
    User deploy
    ProxyJump bastion
    IdentityFile ~/.ssh/id_ed25519_prod

$ ssh internal-db
# transparently: connect to bastion, then jump to 10.0.5.20 — one command
```

**4. Local port forward — reach an internal-only Postgres from your laptop**
```bash
$ ssh -L 5433:10.0.5.20:5432 -N -f bastion
$ psql -h localhost -p 5433 -U app_user appdb
# traffic: localhost:5433 -> bastion (encrypted) -> 10.0.5.20:5432
psql (14.9)
Type "help" for help.
appdb=>
```

**5. Remote forward — expose a local dev webhook receiver to a cloud VM**
```bash
$ ssh -R 8080:localhost:3000 -N -f cloud-vm
# now anything hitting cloud-vm:8080 tunnels back to my laptop's localhost:3000
$ curl http://cloud-vm-public-ip:8080/webhook-test
{"status":"received"}
```

**6. Dynamic forward — SOCKS proxy through a jump host**
```bash
$ ssh -D 1080 -N -f bastion
$ curl -x socks5h://localhost:1080 https://ifconfig.me
203.0.113.10          # egress IP is the bastion's, confirming traffic routed through it
```

**7. rsync mirror with dry-run safety check**
```bash
$ rsync -avzn --delete /srv/app/build/ deploy@10.0.1.15:/var/www/app/
sending incremental file list
deleting old-bundle.js
new-bundle.js
index.html
sent 1,204 bytes  received 87 bytes
(DRY RUN)

$ rsync -avz --delete -e "ssh -p 2222" /srv/app/build/ deploy@10.0.1.15:/var/www/app/
sending incremental file list
new-bundle.js
       48,203 100%   12.34MB/s    0:00:00 (xfr#1, to-chk=1/3)
sent 48,412 bytes  received 89 bytes  32,333.67 bytes/sec
```

**8. scp vs rsync resume behavior on a flaky connection**
```bash
$ scp bigdump.sql.gz deploy@10.0.1.15:/backups/
bigdump.sql.gz    45%   90MB  2.1MB/s   01:12 ETA
ssh: connect to host 10.0.1.15 port 22: Connection timed out
# scp: transfer is DEAD, must restart from 0

$ rsync -P --partial bigdump.sql.gz deploy@10.0.1.15:/backups/
bigdump.sql.gz
      99,999,999  50%   2.30MB/s    0:00:30
# connection drops, then re-run the same command:
$ rsync -P --partial bigdump.sql.gz deploy@10.0.1.15:/backups/
bigdump.sql.gz
     200,000,000  100%   9.80MB/s    0:00:08 (xfr#1, to-chk=0/1)
# rsync resumed from the partial file instead of re-sending everything
```

## Practice Questions

1. Walk through exactly what happens cryptographically when you `ssh` into a server using key-based auth — what's exchanged, and why is the private key never transmitted?
2. Why does sshd refuse a private key or `authorized_keys` file that's group- or world-readable? What are the correct permissions for `~/.ssh`, private keys, and `authorized_keys`?
3. Explain the difference between `-L`, `-R`, and `-D` in `ssh`, and give a realistic production scenario for each.
4. You need to reach a database on a private subnet that's only reachable from a bastion host, without exposing the DB port publicly. How would you set this up with `~/.ssh/config` and/or a `-L` tunnel?
5. What is `ssh-agent` and what problem does it solve? What's the security risk of `ForwardAgent yes`, and what's a safer alternative for jump-host scenarios (hint: `ProxyJump`)?
6. Your `scp` transfer of a 5GB file dies at 60% partway through a flaky VPN. What tool/flags would you use instead to resume rather than restart, and why does scp not support this natively?
7. What does `rsync -a` actually expand to / preserve? Why would you always run `--delete` with `-n` first before the real sync?
8. Given `Host internal-db` with `ProxyJump bastion` in `~/.ssh/config`, what is happening under the hood when you run `ssh internal-db` — does the bastion see the traffic to `internal-db` in plaintext?
9. What's the difference in behavior/security between `ssh -o StrictHostKeyChecking=no` and normal host key verification? Why is disabling it dangerous in production automation, and what's a safer pattern (e.g., pre-populating `known_hosts`)?
10. You need to give a CI pipeline SSH access to deploy to production without a human typing a passphrase. How would you generate and store the key, and what would you restrict on the `authorized_keys` entry (hint: `command=`, `no-port-forwarding`)?

## Real Interview Questions (Company-Attributed)

- "You have a public key and want to give a developer access to a server — where do you store the public key?" — asked at *Alphadyne*
- "Apart from a password, what's another way to log in to a server (e.g. EC2)?" — asked at *Five9*
- "How do you enable passwordless authentication between two servers?" — asked at *an unnamed company (via community-sourced interview notes)*
- "How do you log in to a VM that only has a private IP?" — asked at *CTS*
- "Write a shell script where VM `ubuntu1` has auto-SSH enabled (`ssh -i` with a private key) and copies a directory (`/nobackup`) to another VM." — asked at *Cisco*
- "Write a script to monitor a directory and automatically copy new files to a remote server using SCP." — asked at *Cisco*
- "Explain the use of `scp`." — asked at *Nitor Infotech*

## Interview Key Points

- Know **why the private key never leaves the client** — public-key auth is a challenge-response signature scheme, not a password-style transmission; this trips up candidates who conflate it with password auth over TLS.
- **File permission gotchas are a classic screening question**: `700` on `~/.ssh`, `600` on private keys and `authorized_keys` — sshd fails silently/cryptically ("permission denied (publickey)") if these are wrong, and diagnosing that from symptoms alone is a good signal.
- Clearly distinguish `-L` (local→remote), `-R` (remote→local), and `-D` (SOCKS/dynamic) — this is one of the most commonly garbled topics; use the "which side initiates the local listener and where does traffic egress" framing.
- `ProxyJump` (`-J`) is the modern, single-hop-config way to reach bastioned hosts — know it replaces the older, clunkier `ProxyCommand ssh -W %h:%p bastion`.
- Agent forwarding security tradeoff: convenient for multi-hop but a compromised intermediate host can hijack your agent socket to authenticate as you elsewhere — mention `ProxyJump` as the safer alternative since it doesn't expose your agent to the bastion at all.
- **`rsync` vs `scp`**: rsync does delta-transfer and resume (`--partial`, `-P`), scp does not — for large/flaky transfers this is a real operational difference, not just trivia.
- `rsync --delete` without `-n`/`--dry-run` first is a classic "deleted prod files" interview cautionary tale — always mention dry-run discipline.
- For automation/CI keys: restrict `authorized_keys` entries with `command="..."`, `no-port-forwarding`, `no-agent-forwarding`, `no-X11-forwarding` to limit blast radius of a leaked automation key — senior-level answer beyond "just add the key."
