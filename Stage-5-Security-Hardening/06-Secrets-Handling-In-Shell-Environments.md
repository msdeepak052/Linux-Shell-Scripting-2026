# Secrets Handling in Shell Environments

Plaintext secrets in env vars, `.env` files, shell history, and process listings are one of the most common real-world breach vectors — treat every shell as a hostile, leaky environment by default.

## Explanation

**Why shells leak secrets by default**:
- **Shell history** (`~/.bash_history`, `~/.zsh_history`) persists every command typed, including `export API_KEY=sk-live-xxx` or `curl -H "Authorization: Bearer xxx"` — readable by anyone who gets the file or the account.
- **Process list** (`ps aux`, `/proc/<pid>/cmdline`) exposes command-line arguments to *any* local user by default. `mysql -u root -pSecretPass` puts `SecretPass` in `ps aux` output for everyone on the box.
- **Environment variables** are inherited by every child process and are readable via `/proc/<pid>/environ` by the process owner (or root). They also get dumped in crash logs, CI job logs, and `env`/`printenv` output — easy to leak accidentally in a `set -x` trace or a support bug report.
- **`.env` files** are plaintext on disk, often world-readable by default (`644`), frequently `git add`-ed by accident, and readable by anything with filesystem access (backup tools, other services, container image layers if `COPY . .` is used).

**Mitigations, in order of preference**:
1. **Secret managers / vaults** (HashiCorp Vault, AWS Secrets Manager, GCP Secret Manager, Azure Key Vault) — secrets fetched at runtime, short-lived, never touch disk in plaintext, access is audited.
2. **File-based secrets with tight permissions**, injected by the orchestrator (Docker/Kubernetes secrets mounted as files, systemd `LoadCredential=`) instead of env vars.
3. **Env vars from a non-history, non-logged source** — e.g., `export $(cat secrets.env | xargs)` run from a script (not typed interactively), or `--env-file` passed to `docker run` (still plaintext on disk, but at least out of shell history).
4. Never pass secrets as CLI arguments — use stdin, files, or env vars instead (CLI args are visible in `ps`).

**History hygiene**:
- `HISTCONTROL=ignorespace` — prefixing a command with a space skips it from history.
- `unset HISTFILE` or `export HISTFILE=/dev/null` for a fully unlogged session.
- `history -d <line>` to delete a specific already-logged entry; `history -c` clears the in-memory history (does not touch the file until it's written).
- `.bash_history` should be `chmod 600`, owned by the user, and ideally excluded from backups that might be less protected.

**`.env` file risks specifically**:
- Frequently committed to git by mistake — always `.gitignore` it, and use `git-secrets` / pre-commit hooks / `gitleaks` to catch it before it happens.
- Loaded via `source .env` or `export $(grep -v '^#' .env | xargs)` — both put values into the shell's env, inheritable by every child process (including ones that might log them).
- No access control beyond file permissions — no audit trail of who/what read it, no rotation, no expiry.

**Vault/secret-manager CLI patterns**:
```bash
vault kv get -field=password secret/prod/db          # HashiCorp Vault, fetch a single field
aws secretsmanager get-secret-value --secret-id prod/db/password --query SecretString --output text
```
The pattern: fetch just-in-time into a variable held only in the running process's memory, never written to disk, short TTL if using dynamic credentials.

## Hands-On Examples

**1. Proving env vars leak via `/proc`**
```bash
$ export DB_PASSWORD=SuperSecret123
$ sleep 300 &
[1] 48213
$ cat /proc/48213/environ | tr '\0' '\n' | grep DB_PASSWORD
DB_PASSWORD=SuperSecret123
```
Any process (or user with permission) inspecting `/proc/<pid>/environ` for a running process sees every env var it inherited — including secrets.

**2. Proving CLI args leak via `ps`**
```bash
$ mysql -u root -pSuperSecret123 -e "SELECT 1" &
[1] 48301
$ ps aux | grep mysql
root     48301  0.0  0.1  mysql -u root -pSuperSecret123 -e SELECT 1
```
Compare with the safe form — no password visible in `ps`:
```bash
$ mysql -u root -p -e "SELECT 1" <<< "SuperSecret123"
# or, better: use a config file with restricted perms
$ cat ~/.my.cnf
[client]
password=SuperSecret123
$ chmod 600 ~/.my.cnf
$ mysql -u root -e "SELECT 1"    # reads password from ~/.my.cnf, nothing in ps
```

**3. Keeping a single command out of shell history**
```bash
$ echo $HISTCONTROL
ignoredups
$ export HISTCONTROL=ignoreboth:ignorespace

$  export API_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx    # leading space = not recorded
$ history | tail -3
  501  export HISTCONTROL=ignoreboth:ignorespace
  502  history | tail -3
```
Note the `export API_TOKEN=...` line never appears — the leading space suppressed it.

**4. `.env` file accidentally staged in git — catching it before commit**
```bash
$ ls -la
-rw-r--r-- 1 dev dev  212 Aug  8 10:02 .env
$ git status
Untracked files:
  .env

$ echo ".env" >> .gitignore
$ git add .gitignore
$ gitleaks detect --source . --verbose
Finding:     DB_PASSWORD=SuperSecret123
Secret:      SuperSecret123
RuleID:      generic-api-key
File:        .env
$ chmod 600 .env    # at minimum, restrict to owner
```

**5. Fetching a secret from Vault just-in-time, never touching disk**
```bash
$ export VAULT_ADDR=https://vault.internal:8200
$ export VAULT_TOKEN=$(cat /run/secrets/vault-token)   # token itself injected by orchestrator, not typed
$ DB_PASS=$(vault kv get -field=password secret/prod/db)
$ psql "postgresql://appuser:${DB_PASS}@db.internal/prod" -c "SELECT 1"
 ?column?
----------
        1
$ unset DB_PASS   # scrub from shell env once used
```

**6. AWS Secrets Manager CLI pattern in a deploy script**
```bash
$ cat > deploy.sh << 'EOF'
#!/bin/bash
set -euo pipefail
SECRET=$(aws secretsmanager get-secret-value \
    --secret-id prod/app/api-key \
    --query SecretString --output text)
docker run -d --name app \
    -e API_KEY="$SECRET" \
    myapp:latest
unset SECRET
EOF
$ ./deploy.sh
```
Even here, `-e API_KEY=...` still ends up in `docker inspect` output on that host — Kubernetes `Secret` objects mounted as files, or Docker `--env-file` combined with `docker secret` in Swarm mode, avoid this exposure.

**7. Kubernetes Secret mounted as a file (avoiding env var exposure entirely)**
```bash
$ kubectl create secret generic db-creds --from-literal=password=SuperSecret123
secret/db-creds created

$ cat pod.yaml
    volumeMounts:
    - name: db-creds
      mountPath: /run/secrets/db
      readOnly: true
  volumes:
  - name: db-creds
    secret:
      secretName: db-creds

$ kubectl exec -it app-pod -- cat /run/secrets/db/password
SuperSecret123
```
File-based mounts avoid `kubectl describe pod` and `env` dumps leaking the value the way `env:` + `secretKeyRef` (still readable via `/proc/.../environ` inside the container) can.

**8. Auditing a running system for exposed secrets**
```bash
$ for pid in $(pgrep -u appuser); do
    grep -aE 'PASSWORD|SECRET|TOKEN|API_KEY' /proc/$pid/environ 2>/dev/null \
      && echo "  ^-- leaked in PID $pid ($(ps -p $pid -o comm=))"
  done
PASSWORD=SuperSecret123API_KEY=sk-liveTOKEN=ghp_xxx
  ^-- leaked in PID 48301 (legacy-worker)
```
A quick way to find services still passing secrets via env vars that should be migrated to a vault-based fetch pattern.

## Practice Questions

1. Why is passing a password as a CLI argument (e.g., `mysql -pSecret`) worse than passing it via an env var or stdin? What tool exposes the CLI argument to other local users?
2. A developer's `~/.bash_history` shows `export AWS_SECRET_ACCESS_KEY=AKIA...`. What two changes (one for the future, one for right now) would you make?
3. Explain how `/proc/<pid>/environ` can leak a secret even if it was never typed into an interactive shell (e.g., injected by a systemd unit or Docker `-e` flag).
4. What's wrong with `.env` files as a long-term secrets strategy, even if `.gitignore` correctly excludes them?
5. Describe the difference between injecting a secret as a Kubernetes env var (`secretKeyRef`) versus mounting it as a file, and why the file approach is generally preferred for sensitive values.
6. What does `HISTCONTROL=ignorespace` do, and what's a scenario where relying on it is risky (i.e., where it fails to protect you)?
7. You're asked to rotate a leaked API key that was committed to git six months ago and merged into `main`. Beyond rotating the key itself, what else needs to happen given git's history retention?
8. Write a one-line command to scan a running process's environment for anything matching `PASSWORD|SECRET|TOKEN`, and explain a legitimate use case for doing this as part of a security audit.
9. What's the tradeoff between a static long-lived secret pulled once at startup versus a vault-issued dynamic/short-TTL credential fetched per-request or per-session?
10. A CI pipeline logs `env` output for debugging on failure. What's the risk, and how would you prevent secrets from ending up in CI logs while still allowing useful debug output?

## Interview Key Points

- **CLI arguments are visible to every local user via `ps aux` / `/proc/<pid>/cmdline`** — this is the #1 "why is this insecure" trap; always push secrets via stdin, files, or env vars instead of `-p`/`--password=` style flags.
- **Env vars are not actually secret** — they're inherited by every child process and readable via `/proc/<pid>/environ`; treat them as "less bad than CLI args" but not as a real secrets store.
- **`.env` files are plaintext with no access control, audit trail, or rotation** — fine for local dev, a red flag in production; the interviewer wants to hear "vault/secrets manager" as the production answer.
- **Git history is forever** — a secret committed once and later removed is still in every clone's history; the fix requires rotating the secret AND rewriting history (`git filter-repo`/BFG) or accepting the leak as permanent.
- Know the **file-mount vs env-var** distinction for Kubernetes/Docker secrets — file mounts avoid `docker inspect`/`kubectl describe`/`/proc/environ` exposure that env-var injection doesn't.
- **Shell history hygiene** (`HISTCONTROL=ignorespace`, `HISTFILE=/dev/null`, `chmod 600 ~/.bash_history`) is a cheap, commonly-asked mitigation — know it even though it's not a substitute for a real secrets manager.
- Dynamic, short-TTL credentials (Vault dynamic secrets, AWS STS) are the senior-level answer to "how do you limit blast radius of a leaked credential" — static long-lived secrets are the anti-pattern.
- Be ready to name at least one vault/secret-manager CLI invocation from memory (`vault kv get`, `aws secretsmanager get-secret-value`) — interviewers often ask you to sketch the fetch pattern in a deploy script.
