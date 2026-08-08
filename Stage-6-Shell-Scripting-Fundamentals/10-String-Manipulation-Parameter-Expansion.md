# String Manipulation & Parameter Expansion

Bash can do a surprising amount of text manipulation with zero external tools (no `awk`/`sed` needed) — faster and more portable for simple cases.

## Explanation

**Length**: `${#var}` — number of characters.

**Substring extraction**: `${var:start}` / `${var:start:length}` — zero-indexed, negative start needs a space or parens to avoid parsing as default-value syntax.

**Default/alternate values**:
| Syntax | Meaning |
|---|---|
| `${var:-default}` | Use `default` if `var` is unset OR empty (doesn't modify `var`) |
| `${var:=default}` | Same, but also ASSIGNS `default` to `var` |
| `${var:+alt}` | Use `alt` ONLY IF `var` is set and non-empty (else empty string) |
| `${var:?error message}` | Print error and exit if `var` is unset/empty — great for required-variable checks |

**Pattern trimming** (glob patterns, not regex):
| Syntax | Meaning |
|---|---|
| `${var#pattern}` | Remove **shortest** match of `pattern` from the **front** |
| `${var##pattern}` | Remove **longest** match of `pattern` from the **front** |
| `${var%pattern}` | Remove **shortest** match of `pattern` from the **end** |
| `${var%%pattern}` | Remove **longest** match of `pattern` from the **end** |

**Substitution**:
| Syntax | Meaning |
|---|---|
| `${var/pattern/repl}` | Replace **first** match |
| `${var//pattern/repl}` | Replace **all** matches |
| `${var/#pattern/repl}` | Replace only if match is at the **start** |
| `${var/%pattern/repl}` | Replace only if match is at the **end** |

**Case conversion** (bash 4+): `${var^}` (first char upper), `${var^^}` (all upper), `${var,}` (first char lower), `${var,,}` (all lower).

## Hands-On Examples

**1. Length and substring**
```bash
$ version="v2.3.1-rc4"
$ echo "${#version}"
10

$ echo "${version:1}"        # from index 1 to end (drop the leading 'v')
2.3.1-rc4

$ echo "${version:1:5}"      # 5 chars starting at index 1
2.3.1
```

**2. Default values — handling optional config**
```bash
$ echo "Environment: ${ENVIRONMENT:-development}"
Environment: development

$ export ENVIRONMENT=production
$ echo "Environment: ${ENVIRONMENT:-development}"
Environment: production

$ unset LOG_LEVEL
$ echo "Log level: ${LOG_LEVEL:+overridden}"    # empty because LOG_LEVEL is unset
Log level: 

$ export LOG_LEVEL=debug
$ echo "Log level: ${LOG_LEVEL:+overridden}"
Log level: overridden
```

**3. Required-variable enforcement — fail fast in production scripts**
```bash
$ cat > require_var.sh << 'EOF'
#!/bin/bash
: "${DB_PASSWORD:?ERROR: DB_PASSWORD must be set}"
echo "Connecting with provided password..."
EOF
$ ./require_var.sh
./require_var.sh: line 2: DB_PASSWORD: ERROR: DB_PASSWORD must be set
$ echo $?
1

$ DB_PASSWORD=secret123 ./require_var.sh
Connecting with provided password...
```

**4. Extracting a filename/extension from a path — `#`/`##`/`%`/`%%` in action**
```bash
$ path="/var/log/nginx/access.log.2026-08-08.gz"

$ echo "${path##*/}"             # longest match of */ from front -> just the filename
access.log.2026-08-08.gz

$ echo "${path%/*}"              # shortest match of /* from end -> just the directory
/var/log/nginx

$ echo "${path##*.}"             # longest match of *. from front -> last extension
gz

$ file="report.tar.gz"
$ echo "${file%%.*}"             # longest match of .* from end -> strip ALL extensions
report
$ echo "${file%.*}"              # shortest match of .* from end -> strip LAST extension only
report.tar
```

**5. String replacement — sanitizing/transforming values**
```bash
$ log_line="ERROR: connection timeout at 10.0.1.5"
$ echo "${log_line/ERROR/WARN}"
WARN: connection timeout at 10.0.1.5

$ csv_row="web01,10.0.1.5,active,prod"
$ echo "${csv_row//,/ | }"        # replace ALL commas with " | " for pretty printing
web01 | 10.0.1.5 | active | prod

$ hostname_raw="WEB-SERVER-01.INTERNAL"
$ echo "${hostname_raw,,}"         # lowercase everything
web-server-01.internal
```

**6. Real-world: parsing a simple CSV row using pure bash parameter expansion (no awk)**
```bash
$ row="app-server,web01,10.0.1.5,running,prod"

$ name="${row%%,*}"                       # everything before first comma
$ rest="${row#*,}"                        # everything after first comma
$ echo "Service: $name"
Service: app-server

$ host="${rest%%,*}"
$ rest="${rest#*,}"
$ echo "Host: $host"
Host: web01

$ ip="${rest%%,*}"
$ rest="${rest#*,}"
$ echo "IP: $ip"
IP: 10.0.1.5
```
This manual field-walking works but gets tedious past 3-4 fields — for real CSV work, `IFS=',' read -ra fields <<< "$row"` (Stage 4) or `awk -F,` (Stage 7) scale much better. Good to know pure-expansion parsing is *possible*, but recognize when to switch tools.

**7. Case conversion for consistent naming (e.g., normalizing env names)**
```bash
$ env_input="Production"
$ echo "${env_input,,}"     # normalize to lowercase before comparison
production

$ service="payment-api"
$ echo "${service^^}"        # e.g., building an env var name from a service name
PAYMENT-API
$ env_var_name="${service^^}_PORT"
$ env_var_name="${env_var_name//-/_}"
$ echo "$env_var_name"
PAYMENT_API_PORT
```

**8. Trimming whitespace with pattern trimming (common when parsing config files)**
```bash
$ raw="   value with spaces   "
$ trimmed="${raw#"${raw%%[![:space:]]*}"}"    # trim leading whitespace
$ trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"  # trim trailing whitespace
$ echo "[$trimmed]"
[value with spaces]
```

## Practice Questions

1. Given `file="/etc/nginx/sites-available/default.conf"`, write parameter expansions to extract just `default.conf`, just the directory `/etc/nginx/sites-available`, and just the extension `conf`.
2. What's the difference between `${var#pattern}` and `${var##pattern}`? Construct an example where they give different results.
3. Write a required-variable check using `${VAR:?message}` for an `API_KEY` environment variable that must be set before a script proceeds, and show what happens when it's missing.
4. What's the difference between `${var:-default}` and `${var:=default}`? After running `echo "${x:=fallback}"` on an unset `x`, what is `$x` afterward?
5. Given `name="John Smith"`, write the parameter expansion to convert it to `john smith` (all lowercase) and separately to `JOHN SMITH` (all uppercase).
6. Write a one-liner using `${var//pattern/repl}` to replace every space in a string with an underscore.
7. Given `version="v10.2.5"`, extract just `10`, just `2`, and just `5` (major/minor/patch) using only parameter expansion (`#`, `##`, `%`, `%%`) — no external tools.
8. What does `${#array[@]}` return versus `${#string}`? Are they using the same `#` operator for different purposes?
9. Given `path="app.tar.gz"`, what's the difference between `${path%.*}` and `${path%%.*}`? Show both outputs.
10. Write a snippet that reads an environment variable `RETRY_COUNT`, defaults it to `3` if unset (without permanently modifying the original unset state), and prints the value used.

## Interview Key Points

- Parameter expansion (`${var...}`) is a **bash built-in feature — zero forked processes** — vastly faster than piping through `sed`/`awk`/`cut` for simple string operations; worth mentioning as a performance-conscious answer.
- `${var#pattern}` (front, shortest) vs `${var##pattern}` (front, longest) vs `${var%pattern}` (end, shortest) vs `${var%%pattern}` (end, longest) — the `#`=front/`%`=end and single=shortest/double=longest mnemonics are commonly tested; be ready to demo extracting a filename and extension from a path live.
- `${var:-default}` (non-destructive) vs `${var:=default}` (destructive, assigns) vs `${var:?msg}` (fail-fast) vs `${var:+alt}` (only-if-set) — these four are a classic "explain the difference" interview cluster; know all four, not just `:-`.
- `${VAR:?error message}` is the idiomatic pure-bash way to enforce required environment variables/arguments early in a production script — a strong senior-level answer to "how do you validate required inputs."
- These operators use **glob patterns** (`*`, `?`, `[...]`), NOT regex — a common point of confusion; `${var#*.}"` uses `*` as a glob wildcard, not a regex "zero or more."
- Know when to STOP using pure parameter expansion: manually walking multiple CSV fields with `%%,*`/`#*,` gets unreadable past a few fields — recognizing when to reach for `awk -F,` or `read -ra` instead is itself a signal of engineering judgment.
- Case conversion (`^^`, `,,`) requires bash 4+ — same portability caveat as associative arrays (breaks on old macOS default bash).
