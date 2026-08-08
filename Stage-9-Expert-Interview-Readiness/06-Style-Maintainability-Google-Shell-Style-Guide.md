# Style & Maintainability (Google Shell Style Guide, Code Review Practices)

Bash is easy to write badly and hard to review carelessly — a shared style guide and disciplined review habits are what keep production scripts maintainable past the person who wrote them.

## Explanation

**Why a style guide matters more for shell than most languages:** bash has an unusually large surface area of "technically works, but fragile/ambiguous" constructs (unquoted variables, `[ ]` vs `[[ ]]`, backticks vs `$()`, word-splitting surprises). Without agreed conventions, every script looks different and every reviewer re-litigates the same basic questions. The [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html) is the most widely cited reference; know its major positions even if your team's own guide differs slightly.

**Google Shell Style Guide — key positions:**
- **When to use shell at all**: only for small utilities or simple wrapper scripts, primarily calling other tools with little data manipulation. If you're manipulating structured data, writing anything performance-critical, or the logic exceeds ~100 lines with non-straight-line control flow, **use a different language** — this is stated explicitly in the guide.
- **Always use `#!/bin/bash`** (not `sh`) if using bash-specific features, and set the shebang correctly — never rely on the script being invoked a particular way.
- **Use `$(command)` not backticks** — nesting backticks requires escaping and is far less readable.
- **Always quote variables**: `"$var"` not `$var`, to prevent word-splitting/globbing bugs. This is the single most-cited rule.
- **Use `[[ ]]` not `[ ]`** for conditionals in bash — safer (no word-splitting on unquoted vars inside it, supports `&&`/`||`/regex `=~` natively).
- **Use `readonly` or `local`** appropriately — constants marked `readonly`, function variables marked `local` to avoid polluting global scope.
- **Function names**: `lower_snake_case` with `()`, no `function` keyword needed (though the guide allows it consistently within a file).
- **Constants and environment variables**: `UPPER_SNAKE_CASE`, declared at the top of the file.
- **Always check return values** — explicitly, not relying on accidental propagation; prefer explicit `if ! mv "$src" "$dst"; then ... fi` over hoping `set -e` catches everything.
- **Use `main()`** as the entry function, called explicitly at the bottom of the script (`main "$@"`) — makes scripts sourceable for testing (see file 05) and keeps top-level logic out of global scope.
- **STDOUT for output, STDERR for errors/logging** — never mix; makes piping and log-parsing predictable.
- Prefer **`${var}` in string interpolation** when adjacent to other text (`"${var}_suffix"`) to avoid ambiguity.

**Code review practices specific to shell scripts:**
- **Run `shellcheck` as a mandatory CI gate**, not just an editor suggestion — it catches the large majority of quoting/globbing/word-splitting bugs automatically, freeing human reviewers to focus on logic and structure.
- **Review for idempotency** — can this script be re-run safely if it fails halfway? This is a shell-specific review question that doesn't come up the same way in application code.
- **Review for blast radius** — does this script `rm -rf` or otherwise mutate state based on a variable that could be empty/unset (`rm -rf "$dir"/*` when `$dir` is accidentally empty deletes `/*`)? This class of bug is specific to shell and worth explicitly scanning for.
- **Check for hardcoded paths/secrets/environment assumptions** that will break outside the author's machine.
- **Verify error handling exists at every external call** (network, filesystem, subprocess) — not just the happy path.
- **Prefer small, single-purpose scripts** over large multi-mode ones (`deploy.sh --mode=x`) — easier to review, test, and reason about independently.

## Hands-On Examples

**1. Unquoted variable — the single most common review finding**
```bash
# BAD — breaks on filenames with spaces, and on glob characters
$ rm -rf $BUILD_DIR/*
# if $BUILD_DIR happens to be empty/unset, this becomes: rm -rf /*

# GOOD
$ rm -rf "${BUILD_DIR:?BUILD_DIR must be set}"/*
# ${VAR:?msg} aborts with an error if VAR is unset or empty — a critical guard
# specifically for destructive commands
```

**2. `shellcheck` catching real bugs automatically**
```bash
$ cat deploy.sh
#!/bin/bash
files=$(find . -name "*.log")
for f in $files; do
    rm $f
done

$ shellcheck deploy.sh
In deploy.sh line 2:
files=$(find . -name "*.log")
^-- SC2035 (info): Use ./*.log so names with dashes won't become options.

In deploy.sh line 3:
for f in $files; do
         ^-- SC2086 (info): Double quote to prevent globbing and word splitting.

In deploy.sh line 4:
    rm $f
       ^-- SC2086 (info): Double quote to prevent globbing and word splitting.
```
The idiomatic fix (also suggested by convention, not just shellcheck) is to avoid parsing `find` output as words at all:
```bash
$ find . -name "*.log" -print0 | while IFS= read -r -d '' f; do
    rm -- "$f"
done
```

**3. `[[ ]]` vs `[ ]` — a concrete failure `[ ]` allows through**
```bash
$ var="a b"
$ [ $var = "a b" ] && echo "match"
bash: [: too many arguments        # word-splitting broke the unquoted comparison

$ [[ $var = "a b" ]] && echo "match"
match                               # [[ ]] doesn't word-split unquoted vars inside it
```

**4. `main()` pattern for testability and readability**
```bash
$ cat backup.sh
#!/bin/bash
set -euo pipefail

readonly BACKUP_DIR="/var/backups"

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

validate_source() {
    local src="$1"
    [[ -d "$src" ]] || { log "ERROR: $src is not a directory"; return 1; }
}

do_backup() {
    local src="$1"
    tar -czf "${BACKUP_DIR}/$(basename "$src")_$(date +%Y%m%d).tar.gz" "$src"
}

main() {
    local src="${1:?Usage: backup.sh <source-dir>}"
    validate_source "$src"
    do_backup "$src"
    log "Backup complete"
}

main "$@"
```
This can be `source`d in a bats test without running `main`, and each function is independently reviewable and testable.

**5. STDOUT vs STDERR discipline**
```bash
# BAD — error mixed into stdout, breaks any caller parsing output
$ cat check.sh
echo "Checking service..."
echo "ERROR: service not found"
echo "OK"

# GOOD — errors/logging to stderr, only the actual result on stdout
$ cat check.sh
echo "Checking service..." >&2
echo "ERROR: service not found" >&2
echo "OK"   # only this is meant to be captured/parsed by a caller
$ result=$(./check.sh 2>/dev/null)
$ echo "$result"
OK
```

**6. Reviewing for idempotency — a shell-specific review question**
```bash
# Reviewer question: "what happens if this script is re-run after failing on line 3?"
$ cat setup_user.sh
useradd deploy
mkdir /home/deploy/.ssh
echo "$PUBKEY" >> /home/deploy/.ssh/authorized_keys

# Problem: re-running fails at `useradd` (user already exists) even if steps
# 2-3 never completed, and `>>` means re-running after partial success
# DUPLICATES the key rather than being a no-op.

# Idempotent version:
id deploy &>/dev/null || useradd deploy
mkdir -p /home/deploy/.ssh
grep -qxF "$PUBKEY" /home/deploy/.ssh/authorized_keys 2>/dev/null \
    || echo "$PUBKEY" >> /home/deploy/.ssh/authorized_keys
```

**7. Constants/naming convention consistency**
```bash
# BAD — inconsistent casing, no readonly, unclear scope
max_retries=3
TIMEOUT=30
function doThing() { ... }

# GOOD — Google style: UPPER_SNAKE_CASE constants, lower_snake_case functions
readonly MAX_RETRIES=3
readonly TIMEOUT_SECONDS=30
do_thing() { local x="$1"; ... }
```

**8. A shell-specific code review checklist applied to a real diff**
```bash
$ git diff deploy.sh
+ rm -rf $TMP/*
+ curl http://internal-api/deploy?key=$API_KEY
+ cp config.yml /etc/myapp/config.yml

# Reviewer comments:
# 1. Quote "$TMP" and guard against empty/unset — blast-radius risk (see example 1)
# 2. $API_KEY in a URL query string will appear in shell history, process list,
#    and possibly web server access logs — use a header or POST body instead
# 3. `cp` here isn't idempotent-safe if the process is interrupted mid-write —
#    consider `cp config.yml /etc/myapp/config.yml.tmp && mv ...` for atomicity
# 4. No error check after `curl` — does a failed deploy call get caught?
```

## Practice Questions

1. Why does the Google Shell Style Guide recommend switching to a different language once a script exceeds roughly 100 lines or has non-trivial control flow? What's the underlying risk it's protecting against?
2. What's the concrete bug risk of `rm -rf $dir/*` versus `rm -rf "${dir:?}"/*`, and why is the second form specifically safer?
3. Explain the difference between `[ ]` and `[[ ]]` in bash and give an example input that breaks `[ ]` but not `[[ ]]`.
4. Why does the style guide prefer `$(command)` over backtick syntax, especially for nested command substitution?
5. What does making `shellcheck` a mandatory CI gate (versus an optional editor hint) change about the code review process?
6. What does "idempotency" mean for an operational script, and how would you review a script for it? Give an example of a non-idempotent operation and its fix.
7. Why should error/log output go to stderr while only actual results go to stdout? What breaks if you mix them?
8. Explain the `main() { ... }` / `main "$@"` pattern and what testability benefit it provides that a flat top-level script doesn't.
9. A teammate's script embeds an API key directly in a `curl` URL query string. What are the review concerns, and what's the safer alternative?
10. What review question would you ask about "blast radius" for a script that runs `rm`, `mv`, or writes to shared paths — and why is this a shell-specific concern more than in typical application code?

## Interview Key Points

- Know that the **Google Shell Style Guide explicitly says shell is for small utilities/wrappers only** — recommending a real language past a certain complexity threshold is itself a key, quotable position from the guide.
- **Quoting variables (`"$var"`)** is the single most common shell code review finding — be ready to explain word-splitting/globbing with a concrete broken example.
- **`[[ ]]` over `[ ]`** in bash — safer word-splitting behavior, native `&&`/`||`/regex support; know a concrete case where `[ ]` breaks and `[[ ]]` doesn't.
- **`shellcheck` as a CI gate**, not just a suggestion, is the practical answer to "how do you enforce shell style at scale" — mention it early in any style/review question.
- **Idempotency review** is a shell-specific review lens most candidates from other languages don't think to mention — re-running a script after partial failure should be safe, not destructive or duplicative.
- **Blast-radius awareness**: unset/empty variables feeding into `rm -rf`, `mv`, or other destructive commands is a uniquely dangerous shell footgun — always mention `${VAR:?msg}` guards for destructive operations.
- STDOUT/STDERR discipline (results vs. logging/errors) is what makes scripts safely composable in pipelines — mixing them breaks any caller parsing output.
- The `main "$@"` entry-point pattern connects style directly to testability (file 05) — sourcing a script without executing `main` is how you unit test individual functions.
