# Writing Idempotent Scripts

An idempotent script produces the same end state no matter how many times it's run — critical for config management, provisioning, and cron jobs that might retry after a partial failure.

## Explanation

**Idempotency** means: running the script once, or running it five times in a row, leaves the system in the exact same state with no errors and no duplicated side effects. This is the foundation that tools like Ansible, Terraform, and Puppet are built on — and it's expected of hand-written ops scripts too.

**Core technique: check-before-act (or use commands that are naturally idempotent)**:
- Prefer commands with built-in idempotency over "act blindly" commands:
  - `mkdir -p` (no error if dir exists) instead of `mkdir`
  - `ln -sf` (force-overwrite symlink) instead of `ln -s`
  - `rm -f` (no error if file missing) instead of `rm`
  - `curl -o` / `install` for placing files, `touch` for ensuring existence
  - `iptables -C rule || iptables -A rule` (check before append, since `iptables -A` duplicates rules on every run)
  - `apt-get install -y pkg` — already idempotent (a package manager, not a raw command)
- Guard non-idempotent actions with an explicit check:
  ```bash
  id myuser &>/dev/null || useradd myuser
  grep -qxF "export PATH=..." ~/.bashrc || echo "export PATH=..." >> ~/.bashrc
  ```
- **State files / marker files** — for multi-step processes where re-running expensive steps is wasteful or unsafe, record completion:
  ```bash
  [[ -f /var/lib/myapp/.migrated_v3 ]] || { run_migration_v3; touch /var/lib/myapp/.migrated_v3; }
  ```
- **Declarative over imperative**: instead of "append this line" (which duplicates on rerun), aim for "ensure this line exists" (`grep -qxF ... || echo ... >>`) or "ensure this exact file content" (write the whole file with `cat > file <<EOF`, which is naturally idempotent — same output every time).

**Common idempotency traps**:
- `>>` (append) is NOT idempotent by itself — reruns duplicate entries. Always guard appends with a `grep -q` check first, or use `>` to fully overwrite a managed block/file instead.
- Counters, `mktemp` names based on timestamps, or anything using `$RANDOM`/`date` in the destination path breaks idempotency — the "same input, same output" property is what you're protecting.
- Database `INSERT` is not idempotent; `INSERT ... ON CONFLICT DO NOTHING` (upsert) or `INSERT ... ON DUPLICATE KEY UPDATE` is.
- API calls that create resources (`POST /users`) are often not idempotent; look for or emulate a "create-if-not-exists" variant, or check existence first via `GET`.

## Hands-On Examples

**1. Idempotent directory + symlink setup**
```bash
$ cat > setup_dirs.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p /opt/myapp/releases /opt/myapp/shared/logs
ln -sf /opt/myapp/releases/current /opt/myapp/current
echo "Directory structure ready"
EOF
$ ./setup_dirs.sh && ./setup_dirs.sh   # run twice, no errors either time
Directory structure ready
Directory structure ready
```

**2. Idempotent user creation**
```bash
$ cat > ensure_user.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
USERNAME=deploy

if id "$USERNAME" &>/dev/null; then
    echo "User $USERNAME already exists, skipping"
else
    useradd -m -s /bin/bash "$USERNAME"
    echo "Created user $USERNAME"
fi
EOF
$ ./ensure_user.sh
Created user deploy
$ ./ensure_user.sh
User deploy already exists, skipping
```

**3. Idempotent line-in-file (avoiding duplicate `/etc/hosts` entries)**
```bash
$ cat > ensure_host_entry.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
ENTRY="10.0.0.5 db.internal"
grep -qxF "$ENTRY" /etc/hosts || echo "$ENTRY" >> /etc/hosts
EOF
$ ./ensure_host_entry.sh; ./ensure_host_entry.sh; ./ensure_host_entry.sh
$ grep db.internal /etc/hosts
10.0.0.5 db.internal          # only ONE entry, despite 3 runs
```

**4. Managed config block — fully idempotent via overwrite, not append**
```bash
$ cat > configure_nginx.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat > /etc/nginx/conf.d/myapp.conf << 'CONF'
server {
    listen 80;
    server_name myapp.internal;
    location / { proxy_pass http://127.0.0.1:3000; }
}
CONF
nginx -t && systemctl reload nginx
EOF
$ ./configure_nginx.sh
nginx: configuration file /etc/nginx/nginx.conf test is successful
# Overwriting the whole file every run guarantees identical content regardless of run count
```

**5. State-file gate for a one-time, expensive migration**
```bash
$ cat > migrate.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR=/var/lib/myapp
MARKER="$STATE_DIR/.schema_v3_migrated"
mkdir -p "$STATE_DIR"

if [[ -f "$MARKER" ]]; then
    echo "Migration v3 already applied, skipping"
    exit 0
fi

echo "Running schema v3 migration (expensive)..."
psql -f migrations/v3.sql
touch "$MARKER"
echo "Migration v3 complete, marker written"
EOF
$ ./migrate.sh
Running schema v3 migration (expensive)...
Migration v3 complete, marker written
$ ./migrate.sh
Migration v3 already applied, skipping
```

**6. Idempotent firewall rule (check before append, since `iptables -A` always duplicates)**
```bash
$ cat > allow_ssh.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
RULE="-p tcp --dport 22 -j ACCEPT"
if ! iptables -C INPUT $RULE 2>/dev/null; then
    iptables -A INPUT $RULE
    echo "Rule added"
else
    echo "Rule already present"
fi
EOF
$ ./allow_ssh.sh
Rule added
$ ./allow_ssh.sh
Rule already present
```

**7. Idempotent package + service ensure (declarative wrapper)**
```bash
$ cat > ensure_service.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
PKG=redis-server

dpkg -s "$PKG" &>/dev/null || apt-get install -y "$PKG"
systemctl enable --now "$PKG" &>/dev/null   # enable+start is already idempotent
systemctl is-active --quiet "$PKG" && echo "$PKG is running"
EOF
$ ./ensure_service.sh
redis-server is running
$ ./ensure_service.sh   # rerun: apt-get skips (already installed), systemctl no-ops
redis-server is running
```

**8. Idempotent download using a checksum guard (avoid re-downloading unchanged artifacts)**
```bash
$ cat > fetch_artifact.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
URL="https://artifacts.internal/app-1.4.2.tar.gz"
DEST=/opt/artifacts/app-1.4.2.tar.gz
EXPECTED_SHA="a1b2c3...deadbeef"

if [[ -f "$DEST" ]] && echo "$EXPECTED_SHA  $DEST" | sha256sum -c --quiet 2>/dev/null; then
    echo "Artifact already present and verified, skipping download"
else
    curl -fsSL -o "$DEST" "$URL"
    echo "$EXPECTED_SHA  $DEST" | sha256sum -c --quiet
    echo "Downloaded and verified"
fi
EOF
$ ./fetch_artifact.sh
Downloaded and verified
$ ./fetch_artifact.sh
Artifact already present and verified, skipping download
```

## Practice Questions

1. Define idempotency in your own words in the context of an ops/provisioning script, and explain why it matters for scripts triggered by cron or a retrying orchestrator (e.g., Kubernetes Jobs, Ansible).
2. Why is `echo "some_line" >> config_file` NOT idempotent, and how do you fix it so re-running the script doesn't duplicate the line?
3. Give three examples of Linux commands/flags that are naturally idempotent (safe to rerun) and explain what makes each one safe.
4. Write an idempotent script that ensures a systemd service is installed, enabled, and running — safe to run an unlimited number of times.
5. Why is `iptables -A INPUT ...` not idempotent, and what pattern would you use to make adding a firewall rule idempotent?
6. What is a "marker file" / "state file" pattern, and when would you use it instead of just re-running a check every time (e.g., for an expensive one-time migration)?
7. Is `rm important_file.txt` idempotent? Is `rm -f important_file.txt` idempotent? Explain the distinction being tested here.
8. How would you make a script that downloads and installs an artifact idempotent, avoiding a redundant download AND ensuring correctness if the file was partially/corruptly written on a previous run?
9. Why is a database `INSERT` typically not idempotent, and what SQL pattern(s) make an insert operation idempotent?
10. You inherit a deploy script that appends a new nginx `server` block to a config file on every run. After 10 deploys, nginx fails to reload. Diagnose the idempotency bug and describe the fix.

## Interview Key Points

- Idempotency is the core promise behind config-management tools (Ansible, Puppet, Terraform) — being able to explain and implement it by hand in bash signals you understand *why* those tools are designed the way they are.
- "Check-before-act" and "prefer naturally idempotent commands" are the two go-to strategies — always be ready to name concrete examples: `mkdir -p`, `ln -sf`, `rm -f`, `grep -q ... || append`.
- `>>` (append) is the single most common idempotency bug in real scripts — flag it immediately whenever you see raw append without a preceding existence/content check.
- Overwriting a whole managed file/block (`cat > file <<EOF`) is often simpler and more robust than surgically patching it, and is inherently idempotent — "declarative over imperative" is the underlying principle interviewers want to hear articulated.
- Marker/state files are the right tool for gating expensive, genuinely one-time operations (schema migrations, first-boot provisioning) — know this pattern and its tradeoff (marker can get out of sync with reality if deleted or the action fails after the marker is written but you write the marker in the wrong order).
- Watch for the marker-file ordering bug: write the marker AFTER the action succeeds, never before — otherwise a mid-migration crash leaves a false "completed" marker.
- Idempotency and `set -e`/error handling are complementary: an idempotent script combined with strict mode + trap-based cleanup can be safely retried by an orchestrator after any failure, which is exactly the property production automation needs.
