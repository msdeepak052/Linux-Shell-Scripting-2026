# Documenting & Version-Controlling Operational Scripts

Operational scripts that live outside a "real" application repo are still production code — they need the same README, CHANGELOG, git history, review, and versioning discipline, not a free pass because they're "just scripts."

## Explanation

**Why this matters specifically for ops/platform scripts:** unlike application code, shell scripts (deploy scripts, cron jobs, runbook automation, one-off "fix it" scripts) tend to accumulate in loose directories (`/opt/scripts`, a wiki attachment, someone's home directory) with zero history, no ownership, and no explanation of *why* a given flag or workaround exists. This is exactly the kind of tooling that causes the worst incidents — a script nobody remembers the purpose of, that someone is now afraid to touch or delete. Treating scripts as real code closes that gap.

**What "treating scripts as real code" concretely means:**

- **Every script lives in git**, in a real repo (not a scratch directory, not only on one engineer's laptop) with full commit history — `git blame`/`git log` become your "why was this changed" tool, same as application code.
- **A README per script (or per script collection/repo)** covering: what it does, why it exists, how to run it (usage/flags), prerequisites (required tools, permissions, environment), what it's NOT for, and who owns it. This is what saves the next engineer from having to reverse-engineer intent from the code alone.
- **A CHANGELOG** (or at minimum, meaningful commit messages that double as one) — especially important for scripts run in production, where "what changed between the version that worked and the version that broke things" is a real incident-response question.
- **Semantic versioning for internal tooling** is applicable even without a public release process: `MAJOR.MINOR.PATCH` — MAJOR for breaking changes to flags/behavior/output format that callers depend on, MINOR for backward-compatible new functionality, PATCH for bug fixes. This matters especially when other scripts, cron jobs, or CI pipelines call your script — a MAJOR bump is a signal "check your call sites."
- **Code review before merging**, same as application code — shell is *more* error-prone than most languages per line, so skipping review here is backwards, not justified.
- **Header comments in the script itself** stating purpose, usage, author/team, and last-reviewed date — belt-and-suspenders with the README, useful when a script is copied out of its repo context (which happens more than you'd like).
- **Explicit ownership** (a `CODEOWNERS` entry, or a comment/README line naming the owning team) — "who do I page when this breaks" should never require archaeology.
- **Deprecation process** — when a script is superseded, mark it clearly (README banner, a runtime warning printed to stderr) rather than silently leaving a stale script that someone might still be calling from an old cron entry.

**The version-pinning angle specific to ops scripts:** these scripts are often called by *other* automation (cron, CI, other scripts, Ansible). A change that silently alters output format, a flag's meaning, or exit-code semantics can break callers invisibly — semantic versioning plus a CHANGELOG is how you give downstream callers a chance to notice and adapt, the same courtesy any library API owes its consumers.

## Hands-On Examples

**1. Minimal but complete self-documenting script header**
```bash
#!/usr/bin/env bash
#
# backup_db.sh — Nightly PostgreSQL backup to S3
#
# Usage:   ./backup_db.sh <environment>
# Example: ./backup_db.sh production
#
# Requires: aws-cli v2, pg_dump, jq
# Owner:    platform-team (#platform-oncall)
# Repo:     https://github.com/example/ops-scripts
#
# Version:  2.1.0
# Last reviewed: 2026-06-15
#
set -euo pipefail
...
```
Anyone who finds this file — via `cat`, a stray copy on a server, or scrolling git blame — has everything needed to understand and safely run it, without hunting for a wiki page that may no longer exist.

**2. A proper README for an ops-scripts repo**
```markdown
# ops-scripts/backup

## What this does
Nightly backup of production/staging Postgres databases to S3, invoked by
a systemd timer on `db-01`.

## Usage
    ./backup_db.sh <environment>     # environment: staging | production

## Prerequisites
- AWS credentials with `s3:PutObject` on `s3://acme-backups/`
- `pg_dump` on PATH, matching the target Postgres major version
- Run as the `backup` service account (has readonly DB grants)

## What it does NOT do
- Does not restore backups — see `restore_db.sh` in this repo
- Does not rotate/delete old backups — that's `prune_backups.sh`, run separately

## Owner
platform-team — page via #platform-oncall for failures

## Changelog
See CHANGELOG.md
```

**3. CHANGELOG.md for an internal script — treated like any library**
```markdown
# Changelog

## [2.1.0] - 2026-06-15
### Added
- `--dry-run` flag to preview backup without uploading

## [2.0.0] - 2026-03-02
### Changed
- **BREAKING**: output is now JSON on stdout instead of plain text
  (callers parsing stdout must update; see MIGRATION.md)

## [1.3.1] - 2026-01-10
### Fixed
- Backup failed silently when pg_dump exited non-zero (missing error check)

## [1.3.0] - 2025-11-20
### Added
- Support for `staging` environment (previously production-only)
```
The `2.0.0` entry is exactly the kind of change semantic versioning exists to flag — anything calling this script and parsing its stdout needs to know before pulling the update.

**4. Commit messages that double as changelog material**
```bash
$ git log --oneline -5 backup_db.sh
a3f21c9 fix(backup): check pg_dump exit code before declaring success (fixes silent failures, see INC-4821)
7b9e001 feat(backup): add --dry-run flag for safer testing in staging
c02f88a BREAKING: switch stdout output to JSON for machine-parseable results
91a2ee3 docs: add prerequisites section to README
5f10cd4 refactor: extract validate_env() into its own function for testability
```
Referencing an incident number (`INC-4821`) in a fix commit is a small habit with outsized payoff — six months later, `git log` explains not just *what* changed but *why it mattered*.

**5. `CODEOWNERS` for ops scripts — making ownership machine-enforced, not tribal knowledge**
```bash
$ cat .github/CODEOWNERS
/ops-scripts/backup/       @acme/platform-team
/ops-scripts/deploy/       @acme/release-eng
/ops-scripts/incident/     @acme/sre-team
```
This makes ownership enforced by the PR review process itself, not something you have to remember or ask around about.

**6. Deprecation instead of silent removal**
```bash
$ cat old_deploy.sh
#!/bin/bash
echo "WARNING: old_deploy.sh is DEPRECATED as of 2026-05-01." >&2
echo "Use deploy.sh instead. This script will be removed 2026-09-01." >&2
echo "See MIGRATION.md for the new flags." >&2
sleep 3   # force the caller to actually see the warning, not scroll past it
exec ./deploy.sh "$@"     # forward the call so nothing breaks TODAY
```
This buys migration time for anything still calling the old script (a stale cron entry, someone's muscle memory) instead of a hard break the moment the old script is deleted.

**7. Semantic versioning applied to a script others call**
```bash
$ ./healthcheck.sh --version
healthcheck.sh v3.2.0

# A calling script pins/checks the version it expects:
$ cat caller.sh
REQUIRED_MAJOR=3
actual=$(./healthcheck.sh --version | grep -oP 'v\K[0-9]+')
[[ "$actual" -eq "$REQUIRED_MAJOR" ]] || {
    echo "ERROR: healthcheck.sh major version mismatch (expected v${REQUIRED_MAJOR}.x, got v${actual}.x)" >&2
    exit 1
}
```
This is the same defensive pattern you'd expect from any versioned library dependency — just applied to an internal shell tool instead of an npm/pip package.

**8. Pre-merge review checklist enforced via a PR template**
```markdown
## .github/PULL_REQUEST_TEMPLATE.md (ops-scripts repo)

- [ ] Ran `shellcheck` with zero warnings
- [ ] Updated README if usage/flags/prerequisites changed
- [ ] Updated CHANGELOG.md with a dated entry
- [ ] Bumped version in script header (semver: major/minor/patch as appropriate)
- [ ] If output format or flags changed: confirmed no breaking impact on
      known callers (cron, CI, other scripts) or documented the breakage
- [ ] Tested against a non-production environment
```
Turning the "treat scripts as real code" principle into an actual PR checklist is what makes it stick as a team habit rather than an ideal that erodes under deadline pressure.

## Practice Questions

1. Why is it risky for operational scripts to live outside version control (e.g., only on a server in `/opt/scripts` or attached to a wiki page)? Give a concrete incident scenario this causes.
2. What should a README for an ops script cover at minimum, and why does "what it does NOT do" matter as much as "what it does"?
3. Explain how semantic versioning (MAJOR.MINOR.PATCH) applies to an internal script that other scripts/cron jobs call, with an example of a change that should be a MAJOR bump.
4. A script's stdout output format changes from plain text to JSON. What are the risks if this ships without a version bump or changelog entry, and who is affected?
5. Why should shell scripts go through code review just like application code, given how error-prone shell is per line of code?
6. Describe a deprecation strategy for an old script that's still being called by a stale cron entry somewhere, versus just deleting it outright.
7. What's the value of referencing an incident number (e.g., `INC-4821`) in a commit message that fixes a bug found during that incident?
8. How does a `CODEOWNERS` file remove ambiguity about who to page when an ops script breaks, compared to relying on tribal knowledge?
9. What belongs in a script's own header comment versus in the repo's README — why keep both rather than just one?
10. Your team has a directory of 40 undocumented, unversioned shell scripts that production depends on. What's your prioritized plan to bring them under proper documentation and version control?

## Interview Key Points

- The core framing to lead with: **operational scripts are production code**, not throwaway glue — they deserve README, CHANGELOG, git history, code review, and versioning exactly like application code, because they run in production and other automation depends on them.
- **Semantic versioning for internal tooling** is a slightly non-obvious but strong answer — MAJOR bumps for breaking flag/output/exit-code changes give downstream callers (cron, CI, other scripts) a chance to notice before breaking.
- A **README should state what the script does NOT do** as much as what it does — this prevents scope creep and misuse by the next engineer who finds it.
- **Commit messages referencing incident numbers** for bug-fix commits is a concrete, quotable habit that pays off during future incident postmortems (`git log` becomes an incident-linked history).
- **Deprecation, not silent deletion** — a deprecated script should still work (forward to the replacement) while loudly warning on stderr, to avoid breaking a stale caller nobody remembers exists.
- **`CODEOWNERS`** (or equivalent) makes "who owns this / who do I page" enforced by tooling, not tribal knowledge — a concrete, senior-level answer to "how do you avoid orphaned scripts."
- Tie this file back to file 05 (testing) and file 06 (style/review) — documentation, testing, and style/review together are what make "treat scripts as real code" an actual practice rather than a slogan.
- Watch for the trap of over-engineering: the guide (and Google's own style guide) still says shell is for small utilities — "real code" discipline doesn't mean scripts should grow indefinitely instead of graduating to a proper language when complexity demands it.
