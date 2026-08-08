# Argument Parsing: `getopts`, Flags, and Long Options

Production scripts need real CLI ergonomics — short flags, combined flags, options with values, and often GNU-style `--long-options` — and `getopts` is the POSIX-standard (if limited) tool for it.

## Explanation

**`getopts`** is a bash builtin for parsing **short** options (`-a`, `-b value`) in a loop:
```bash
while getopts "ab:c" opt; do
    case "$opt" in
        a) ;;                 # flag -a (no value)
        b) VAL="$OPTARG" ;;   # -b takes a value, stored in $OPTARG
        c) ;;                 # flag -c
        \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
        :) echo "Option -$OPTARG requires an argument" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))   # remove parsed options, leaving positional args in $@
```
Key mechanics:
- The option string `"ab:c"` — a letter alone means a boolean flag; a letter followed by `:` means it requires an argument (stored in `$OPTARG`).
- A leading `:` in the option string (`":ab:c"`) switches to **silent error mode** — instead of `getopts` printing its own error, it sets `opt` to `?` (unknown option) or `:` (missing required argument) so you can handle errors yourself.
- `$OPTIND` tracks the index of the next argument to process; it must be reset (`OPTIND=1`) if you call `getopts` more than once in the same shell (e.g., in tests).
- `getopts` handles combined short flags like `-abc` automatically (equivalent to `-a -b -c`), and `-b value` or `-bvalue` for options with arguments.
- **`getopts` does NOT support `--long-options`** natively — that's the biggest limitation. Workarounds: hand-roll a `case "$1"` loop with `shift`, or use the external `getopt` (with a `t`) command which supports long options but is less portable (GNU-specific behavior varies from BSD/macOS).

**Hand-rolled long-option parsing** (the common, portable production pattern):
```bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env) ENV="$2"; shift 2 ;;
        --env=*) ENV="${1#*=}"; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;              # end of options marker
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) break ;;                      # first positional arg
    esac
done
```

**Gotchas**:
- Always `shift $((OPTIND - 1))` after a `getopts` loop, or leftover positional args will be misread.
- `--` is the POSIX convention for "everything after this is a positional argument, not a flag" (e.g., a filename starting with `-`) — respect it in hand-rolled parsers.
- Forgetting the leading `:` in the getopts string means getopts prints its own (often unhelpfully generic) error messages instead of yours.
- `$OPTARG` is only meaningful right after the option that set it — same "capture immediately" caveat as `$?`.

## Hands-On Examples

**1. Basic `getopts` — flags and a required value**
```bash
$ cat > deploy.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
VERBOSE=false
ENVIRONMENT=""

while getopts "ve:" opt; do
    case "$opt" in
        v) VERBOSE=true ;;
        e) ENVIRONMENT="$OPTARG" ;;
        \?) echo "Usage: $0 [-v] -e <env>" >&2; exit 1 ;;
    esac
done

echo "verbose=$VERBOSE env=$ENVIRONMENT"
EOF
$ ./deploy.sh -v -e staging
verbose=true env=staging
$ ./deploy.sh -ve staging     # combined short flags
verbose=true env=staging
```

**2. Silent error mode with custom messages**
```bash
$ cat > backup.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
while getopts ":d:o:" opt; do
    case "$opt" in
        d) SRC_DIR="$OPTARG" ;;
        o) OUT_FILE="$OPTARG" ;;
        \?) echo "ERROR: unknown option -$OPTARG" >&2; exit 1 ;;
        :) echo "ERROR: -$OPTARG requires an argument" >&2; exit 1 ;;
    esac
done
echo "Backing up $SRC_DIR to $OUT_FILE"
EOF
$ ./backup.sh -d /var/www -o /backups/www.tar.gz
Backing up /var/www to /backups/www.tar.gz
$ ./backup.sh -d
ERROR: -d requires an argument
$ ./backup.sh -z
ERROR: unknown option -z
```

**3. Consuming positional args after flags with `shift $((OPTIND - 1))`**
```bash
$ cat > copy_files.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
FORCE=false
while getopts "f" opt; do
    case "$opt" in
        f) FORCE=true ;;
    esac
done
shift $((OPTIND - 1))
echo "force=$FORCE, files to copy: $*"
EOF
$ ./copy_files.sh -f file1.txt file2.txt
force=true, files to copy: file1.txt file2.txt
```

**4. Full production deploy script: short + long options mixed by hand**
```bash
$ cat > release.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<USAGE
Usage: $0 --env ENV [--version VER] [--dry-run] [-v]
  --env, -e       Target environment (required)
  --version       Release version (default: latest)
  --dry-run       Print actions without executing
  -v, --verbose   Verbose output
  -h, --help      Show this help
USAGE
}

ENV=""
VERSION="latest"
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--env)     ENV="$2"; shift 2 ;;
        --env=*)      ENV="${1#*=}"; shift ;;
        --version)    VERSION="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; break ;;
        -*)           echo "Unknown option: $1" >&2; usage; exit 1 ;;
        *)            break ;;
    esac
done

[[ -n "$ENV" ]] || { echo "ERROR: --env is required" >&2; usage; exit 1; }
echo "Releasing version=$VERSION to env=$ENV (dry_run=$DRY_RUN, verbose=$VERBOSE)"
EOF
$ ./release.sh --env=prod --version 2.3.1 --dry-run
Releasing version=2.3.1 to env=prod (dry_run=true, verbose=false)
$ ./release.sh -e staging -v
Releasing version=latest to env=staging (dry_run=false, verbose=true)
$ ./release.sh
ERROR: --env is required
Usage: ./release.sh --env ENV [--version VER] [--dry-run] [-v]
  ...
```

**5. Using `--` to pass a filename that looks like a flag**
```bash
$ cat > touch_file.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
while getopts "v" opt; do
    case "$opt" in v) VERBOSE=true ;; esac
done
shift $((OPTIND - 1))
touch -- "$1"
echo "Created: $1"
EOF
$ ./touch_file.sh -- -weird-filename.txt
Created: -weird-filename.txt
```

**6. Validating mutually exclusive / required-together flags**
```bash
$ cat > restore.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
FROM_S3=false
FROM_LOCAL=""

while getopts ":sf:" opt; do
    case "$opt" in
        s) FROM_S3=true ;;
        f) FROM_LOCAL="$OPTARG" ;;
        \?) echo "Unknown option -$OPTARG" >&2; exit 1 ;;
        :) echo "-$OPTARG requires an argument" >&2; exit 1 ;;
    esac
done

if $FROM_S3 && [[ -n "$FROM_LOCAL" ]]; then
    echo "ERROR: -s and -f are mutually exclusive" >&2
    exit 1
fi
echo "restoring from ${FROM_LOCAL:-S3}"
EOF
$ ./restore.sh -s -f /backups/db.sql
ERROR: -s and -f are mutually exclusive
```

**7. Defaults + environment-variable fallback pattern (common in CI scripts)**
```bash
$ cat > ci_build.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
REGISTRY="${DOCKER_REGISTRY:-registry.internal}"

while getopts "r:t:" opt; do
    case "$opt" in
        r) REGISTRY="$OPTARG" ;;
        t) TAG="$OPTARG" ;;
    esac
done
: "${TAG:?ERROR: -t <tag> is required}"
echo "Building ${REGISTRY}/myapp:${TAG}"
EOF
$ DOCKER_REGISTRY=registry.example.com ./ci_build.sh -t v1.2.0
Building registry.example.com/myapp:v1.2.0
$ ./ci_build.sh
./ci_build.sh: line 8: TAG: ERROR: -t <tag> is required
```

**8. External GNU `getopt` for long-option support with reordering**
```bash
$ cat > gnu_style.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
PARSED=$(getopt -o e:v --long env:,verbose,dry-run -n "$0" -- "$@")
eval set -- "$PARSED"

while true; do
    case "$1" in
        -e|--env) ENV="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        --) shift; break ;;
        *) echo "Parse error"; exit 1 ;;
    esac
done
echo "env=$ENV dry_run=${DRY_RUN:-false} verbose=${VERBOSE:-false}"
EOF
$ ./gnu_style.sh --dry-run --env prod -v    # note: flags reordered, still parses correctly
env=prod dry_run=true verbose=true
```

## Practice Questions

1. What's the difference between `"ab:c"` and `":ab:c"` as the option string passed to `getopts`, and why would you prefer the leading colon in a production script?
2. Why doesn't `getopts` support `--long-options` natively, and what are the two common ways to work around that limitation?
3. Write a `getopts`-based script that accepts `-e <environment>` (required), `-v` (verbose flag), and errors out with a usage message if `-e` is missing.
4. What does `shift $((OPTIND - 1))` do, and what bug occurs in a script if you forget to call it after a `getopts` loop?
5. Explain what `$OPTARG` and `$OPTIND` each hold, using a concrete example of `-b value`.
6. How would you support a filename argument that itself begins with a dash, like `-important-file.txt`, without it being misinterpreted as a flag?
7. Design (in words or code) argument parsing for a script that must accept BOTH `--env=prod` and `--env prod` syntax for the same long option.
8. Why does calling `getopts` twice in the same shell session (e.g., across two functions) sometimes silently fail to parse the second call's options correctly, and how do you fix it?
9. Write a hand-rolled (non-getopts) parsing loop supporting `-h`/`--help`, `--dry-run`, and a required `--version VALUE`, that errors on any unrecognized flag.
10. When would you reach for external GNU `getopt` instead of the `getopts` builtin, and what portability caveat should you mention about it?

## Interview Key Points

- Know the fundamental limitation cold: **`getopts` is short-options only** — no `--long-flag` support. This is the #1 fact interviewers check for.
- The leading `:` in the option string (silent error mode) plus handling both `\?` (unknown option) and `:` (missing argument) cases is the mark of a careful implementation versus a toy one.
- `shift $((OPTIND - 1))` after the loop is mandatory to correctly separate flags from positional arguments — a very common thing to forget, and a good "spot the bug" question.
- For real CLIs needing `--long-options`, the standard, portable production pattern is a hand-rolled `while [[ $# -gt 0 ]]; do case "$1" in ... esac; done` loop with explicit `shift`/`shift 2` — know this pattern well enough to write it from memory.
- `--` as an explicit "end of options" marker is a POSIX convention worth mentioning — it lets users pass filenames/args that start with `-` unambiguously.
- Reset `OPTIND=1` if `getopts` needs to be invoked more than once in the same shell process (e.g. in a test harness) — a subtle but real gotcha.
- Mention `${VAR:?error message}` parameter expansion as a clean, idiomatic way to enforce "required" arguments/env vars without a manual `if` check.
