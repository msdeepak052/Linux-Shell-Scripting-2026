# Team Script Standards (Structure, Usage/Help, Exit-Code Conventions)

A script one person can read is a personal tool; a script a whole team can safely run, modify, and debug at 3 AM is engineering — that difference comes down to enforced conventions, not talent.

## Explanation

**Why this matters for seniority**: interviewers use this topic to separate "can write a bash script" from "can be trusted to own the on-call runbook automation." The signal isn't cleverness — it's predictability: every script in the team's repo should look like it was written by the same disciplined person.

**Standard script skeleton** most shops converge on:
```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
```
- `#!/usr/bin/env bash` over `#!/bin/bash` — portable across systems where bash isn't at a fixed path (e.g., macOS with Homebrew bash, containers).
- `IFS=$'\n\t'` — restricts word-splitting to newlines/tabs instead of default space+tab+newline, preventing filenames-with-spaces bugs during loops/globs.

**Usage/help text**: every script accepting arguments should support `-h`/`--help`, print to stdout, and exit 0. This is the single most-checked "is this production quality" box in review.

**Exit-code conventions** (team-wide, documented once, reused everywhere):
- `0` success
- `1` generic/unexpected failure
- `2` usage error (bad arguments)
- `64-78` optionally follow BSD `sysexits.h` (`EX_USAGE=64`, `EX_NOINPUT=66`, `EX_UNAVAILABLE=69`, `EX_CONFIG=78`) for scripts that integrate with stricter tooling
- Reserve a documented range per failure category (e.g., 10-19 = config errors, 20-29 = network errors) so callers (cron, systemd, CI, PagerDuty routing) can branch without parsing text.

**Other structural conventions worth codifying**:
- Constants/config at the top, `main()` function at the bottom, called as `main "$@"` — keeps flow readable top-to-bottom.
- `readonly` for constants that must never be reassigned.
- A `log()`/`die()` helper pair used everywhere instead of raw `echo`.
- Shebang + `set -euo pipefail` + `shellcheck` in CI as a non-negotiable gate — most teams reject PRs that fail `shellcheck -x`.
- Consistent argument parsing (`getopts` for short flags, manual `while`/`case` loop for long flags) rather than every script inventing its own style.
- A version/changelog comment block, or better, rely on git blame/tags instead of embedding change history in-file.

## Hands-On Examples

**1. The team-standard header block**
```bash
#!/usr/bin/env bash
#
# deploy.sh - Deploys the app to the given environment.
# Usage: deploy.sh -e <env> [-v] [-h]
#
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/var/log/${SCRIPT_NAME%.sh}.log"
```

**2. `log()`/`die()` helpers used consistently**
```bash
log()  { printf '[%s] [INFO]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '[%s] [WARN]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }
die()  { printf '[%s] [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; exit "${2:-1}"; }

log "Starting deploy"
[[ -f "$SCRIPT_DIR/config.env" ]] || die "config.env not found" 2
```

**3. Usage/help text pattern with `-h`/`--help`**
```bash
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} -e <environment> [-v] [-h]

  -e ENV     Target environment (staging|production)  [required]
  -v         Verbose output
  -h         Show this help and exit

Examples:
  ${SCRIPT_NAME} -e staging
  ${SCRIPT_NAME} -e production -v
EOF
}

[[ $# -eq 0 ]] && { usage; exit 2; }
```

**4. `getopts` argument parsing with documented exit codes**
```bash
verbose=0
env=""
while getopts ":e:vh" opt; do
    case "$opt" in
        e) env="$OPTARG" ;;
        v) verbose=1 ;;
        h) usage; exit 0 ;;
        \?) echo "Unknown option: -$OPTARG" >&2; usage; exit 2 ;;
        :)  echo "Option -$OPTARG requires an argument" >&2; usage; exit 2 ;;
    esac
done

[[ -z "$env" ]] && die "missing required -e <environment>" 2
[[ "$env" =~ ^(staging|production)$ ]] || die "invalid environment: $env" 2
```

**5. Documented exit-code contract in a comment block (team wiki-friendly)**
```bash
# Exit codes:
#   0  - success
#   1  - unexpected/generic failure
#   2  - usage error (bad or missing arguments)
#   10 - config file missing or invalid
#   20 - remote dependency (API/DB) unreachable
#   30 - deploy step failed, rollback triggered
```
```bash
$ ./deploy.sh -e production; echo "rc=$?"
[2026-08-08 10:02:01] [INFO]  Starting deploy
[2026-08-08 10:02:03] [ERROR] Could not reach artifact registry
rc=20
```

**6. `main()` at the bottom, called explicitly — keeps top-to-bottom readability**
```bash
build_artifact() { log "Building..."; }
run_tests()      { log "Testing..."; }
push_artifact()  { log "Pushing..."; }

main() {
    parse_args "$@"
    build_artifact
    run_tests
    push_artifact
    log "Done"
}

main "$@"
```

**7. `shellcheck` as a CI gate, matching team standard**
```bash
$ shellcheck -x deploy.sh
In deploy.sh line 34:
if [ $env == "production" ]; then
       ^-- SC2166: Prefer [[ ]] over test for string comparisons.
       ^-- SC2086: Double quote to prevent globbing and word splitting.

$ echo "shellcheck: $?"
shellcheck: 1
```
```yaml
# .gitlab-ci.yml snippet enforcing it team-wide
lint:
  stage: test
  script:
    - shellcheck -x scripts/*.sh
```

**8. Consistent trap-based cleanup — part of the "team standard" skeleton**
```bash
tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; log "Cleaned up $tmpdir"; }
trap cleanup EXIT
trap 'die "Interrupted by signal" 130' INT TERM
```

## Practice Questions

1. Why do teams standardize on `#!/usr/bin/env bash` instead of `#!/bin/bash`? Give a concrete scenario where the difference matters.
2. Design an exit-code convention for a team's deploy scripts covering: success, usage error, config error, and remote-dependency error. Explain why callers (e.g., CI, PagerDuty) benefit from this over a single generic non-zero code.
3. What should `-h`/`--help` output include at minimum, and why should it exit `0` rather than `1`?
4. Compare `getopts` vs a manual `while`/`case` argument-parsing loop. When would you need the manual approach?
5. Why put `main "$@"` at the very bottom of a script instead of letting execution just fall through top-to-bottom?
6. What does `IFS=$'\n\t'` protect against, and what's a real bug you'd hit without it when looping over `find` output?
7. How would you enforce these standards across a team of 15 engineers contributing scripts to a shared repo — what tooling/process would you put in CI?
8. A colleague's script uses `echo "ERROR: $msg"` scattered inline instead of a `die()` function. What three things does a proper `die()` helper buy you that scattered `echo` doesn't?
9. Write the header + usage() function for a script `rotate-logs.sh` that takes `-d <dir>` and `-n <days>`, with proper `-h` handling and a usage error exit code.
10. Why is `readonly` for constants considered a best practice in shared/team scripts specifically (as opposed to solo scripts)?

## Interview Key Points

- Standardization signals seniority more than clever one-liners — interviewers probe for `set -euo pipefail`, usage/help text, and a real exit-code taxonomy as baseline expectations.
- Every script that takes arguments must support `-h`/`--help` and exit `0` on it — a script that treats `--help` as a usage error is an instant junior tell.
- Exit codes should be a **documented contract**, not incidental — distinct codes let callers (cron, systemd, CI, alerting) branch on failure category without string-matching log output.
- `shellcheck` in CI is close to industry-standard for team bash repos — know it exists and what class of bugs it catches (quoting, word-splitting, unreachable code).
- `main "$@"` at the bottom + functions above it is the standard "readable top-to-bottom" structure — know how to justify it (easier code review, testable functions).
- `trap ... EXIT` for cleanup and `trap ... INT TERM` for graceful interrupt handling are expected in any script that creates temp files/resources — a common "what's missing from this script" interview prompt.
- Consistent logging helpers (`log`/`warn`/`die`) beat scattered `echo` because they centralize format, destination (stdout vs stderr), and exit behavior — one place to change behavior team-wide.
