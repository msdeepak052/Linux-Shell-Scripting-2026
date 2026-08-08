# Intro to `sed` and `awk` (Single-Line Usage)

The two workhorses of text processing in ops work — `sed` rewrites lines, `awk` understands columns, and together with `grep` they replace most "I'll write a Python script for this" instincts for log parsing, config templating, and CSV/report wrangling.

## Explanation

This file covers **single-line, one-liner usage only** — the 90% of `sed`/`awk` that shows up in daily platform work and in interviews. Full multi-line `awk` programs and complex chained `sed` scripts (functions, loops, multiple pattern-action blocks spanning many lines) are covered later, in the Advanced Shell Scripting stage.

### `sed` — the stream editor

`sed` reads input line by line and applies **editing commands** to each line, printing the result (unless told not to). It never "understands" columns — it works on the line as a string, driven by regex.

**Substitution — the core operation:**
```
sed 's/pattern/replacement/'
```
- By default, replaces only the **first** match per line.
- `g` flag → replace **all** occurrences on the line: `s/pattern/replacement/g`.
- A trailing number → replace only the **Nth** occurrence: `s/pat/rep/2` replaces just the second match on each line.
- `&` in the replacement means "the whole matched text" — useful for wrapping a match without retyping it.
- Capture groups: `\(...\)` (basic regex) or `(...)` with `-E`/`-r` (extended regex) capture text referenced later as `\1`, `\2`, etc. `-E` (GNU/BSD) or `-r` (GNU alias) turns on extended regex so you don't have to backslash-escape `(`, `)`, `+`, `?`, `|` — worth using by default for anything beyond trivial patterns.

**In-place editing (`-i`) — the biggest portability trap in `sed`:**
- GNU `sed` (stock on virtually all Linux distros): `-i` can be used **bare** — `sed -i 's/x/y/' file` edits the file directly, no backup. Or with a backup suffix glued on: `sed -i.bak 's/x/y/' file` (writes `file.bak` before editing).
- BSD/macOS `sed`: `-i` **requires an explicit argument** for the backup suffix, even if you want no backup — you must pass an empty string as a *separate* argument: `sed -i '' 's/x/y/' file`. Omit it and BSD sed swallows your script (`'s/x/y/'`) as the suffix argument instead, then tries to parse the filename as the script, producing a confusing `command a expects \` or `invalid command code` error.
- There is no single flag syntax that's silently correct on both platforms — the portable move (if you must support both) is `sed -i.bak -e '...' file` and then delete the `.bak` afterward, or detect the platform and branch.

**Line/pattern addressing** — restrict a command to specific lines before it runs:
- `sed -n '2p'` → print only line 2. `-n` suppresses `sed`'s default "print every line" behavior, so combined with `p` you get selective printing (this is the classic "poor man's grep with line numbers" pattern).
- `sed '3d'` → delete line 3 (from the output stream; doesn't touch the file unless `-i` is added).
- `sed '2,4d'` → delete a line range (lines 2 through 4).
- `sed '/ERROR/d'` → delete every line matching a pattern.
- `sed '/start/,/end/d'` → delete a **range between two patterns** (inclusive), even when you don't know the line numbers — extremely common for stripping a block out of a config file.

**Multiple expressions in one invocation:** chain with repeated `-e`: `sed -e 's/foo/bar/' -e 's/baz/qux/' file` applies both in sequence, still as a single one-liner.

### `awk` — the field-processing language

`awk` reads input **one record (line) at a time** and automatically splits each line into **fields** based on a separator — by default, any run of whitespace (spaces, tabs), which means it silently handles ragged/variable spacing that would break `cut` (which needs a single literal delimiter character and treats consecutive delimiters as empty fields). This is the single biggest reason to reach for `awk` over `cut` on real-world output like `ps`, `df`, or hand-aligned log lines.

**Built-in variables:**
- `$1`, `$2`, ... → individual fields. `$0` → the entire input line, unmodified.
- `NF` → number of fields in the current line (so `$NF` is always "the last field," `$(NF-1)` the second-to-last — handy when column count varies).
- `NR` → the current record/line number (running count across the whole input).
- `-F` sets a custom field separator: `-F:` for `/etc/passwd`-style colon-delimited data, `-F,` for CSV.

**Pattern-action structure**, `awk`'s core building block: `'pattern { action }'`
- Pattern only, no action (`'/ERROR/'`) → behaves like `grep`: prints the whole line if the pattern matches.
- Action only, no pattern (`'{ print $1 }'`) → runs on **every** line unconditionally.
- Both together (`'/ERROR/ { print $1, $NF }'`) → action runs only on matching lines.

**`BEGIN` / `END` blocks** — the two special patterns that don't match input lines:
- `BEGIN { ... }` runs exactly **once**, before any input is read — used to set `FS` in-code, print a header, or initialize accumulator variables.
- `END { ... }` runs exactly **once**, after all input has been consumed — used to print totals, counts, or averages accumulated while processing each line.
- Together they bookend the classic aggregation idiom: `awk '{sum += $3} END {print sum}'`.

**Numeric context and auto-coercion:** `awk` fields are strings by default, but the moment you use a field in a numeric context (`+`, `>`, `*`, etc.), `awk` automatically coerces it to a number — no explicit cast needed, unlike `bash` arithmetic or most text tools. This is what makes `awk -F, '$3 > 80 {print $1}'` work directly on a CSV column without any `[[ ... ]]` gymnastics.

**`printf` inside `awk`** gives C-style formatted output (`%-10s`, `%5.2f`, etc.) when plain `print`'s space-separated output isn't precise enough — common for aligning report-style output.

### sed vs awk vs grep — which one for which job? (Decision rule)

| Tool | Model | Best for |
|---|---|---|
| `grep` | Whole-line pattern matching | Filtering which lines you see — no transformation |
| `sed` | Line-oriented, regex-driven | Find/replace text, deleting lines/ranges, in-place edits |
| `awk` | Field/column-oriented | Extracting/filtering by column, math across rows, aggregation |

**Bottom line:** if you're *changing* text in place, reach for `sed`; if you're working with *columns* or doing *math across rows*, reach for `awk`; if you're just *filtering which lines you see* with no transformation, `grep` is simplest and fastest. In practice they compose in a pipeline more often than they compete: `grep` narrows the input, `awk` extracts/aggregates, `sort`/`uniq` finish the job.

## Hands-On Examples

**1. Basic `sed` substitution — swapping a hostname in a config file**
```bash
$ cat app.conf
upstream_host=db-primary-old.internal
port=5432
timeout=30

$ sed 's/db-primary-old.internal/db-primary-new.internal/' app.conf
upstream_host=db-primary-new.internal
port=5432
timeout=30
# note: this only PRINTS the result — app.conf itself is unchanged
```

**2. `sed -i` in-place edit — bumping a version string in a deploy manifest (GNU vs BSD gotcha)**
```bash
$ cat deployment.yaml
image: registry.internal/payments-api:1.4.2
replicas: 3

# GNU sed (Linux) — bare -i works, no backup
$ sed -i 's/1\.4\.2/1.4.3/' deployment.yaml
$ cat deployment.yaml
image: registry.internal/payments-api:1.4.3
replicas: 3

# BSD/macOS sed — bare -i FAILS, requires an explicit (even empty) suffix argument
$ sed -i 's/1\.4\.2/1.4.3/' deployment.yaml
sed: 1: "deployment.yaml": invalid command code d
# ^ macOS sed swallowed 's/1\.4\.2/1.4.3/' as the backup suffix and tried
#   to run "deployment.yaml" as a sed script

# Correct on macOS/BSD: empty string as its own argument = no backup
$ sed -i '' 's/1\.4\.2/1.4.3/' deployment.yaml

# Portable across both: always supply a real suffix
$ sed -i.bak 's/1\.4\.2/1.4.3/' deployment.yaml
$ ls
deployment.yaml  deployment.yaml.bak
```

**3. `sed` pattern-address deletion — stripping comments and blank lines from a config**
```bash
$ cat nginx_snippet.conf
# managed by ansible - do not edit manually
server_name api.internal.example.com;

listen 443 ssl;
# TLS settings below
ssl_protocols TLSv1.2 TLSv1.3;

$ sed '/^#/d; /^$/d' nginx_snippet.conf
server_name api.internal.example.com;
listen 443 ssl;
ssl_protocols TLSv1.2 TLSv1.3;
# /^#/d deletes comment lines, /^$/d deletes blank lines, chained with ;
```

**4. `sed` range-pattern deletion — removing a block between two markers**
```bash
$ cat build.env
APP_NAME=checkout-service
# BEGIN-DEPRECATED
LEGACY_CACHE_HOST=cache01.old.internal
LEGACY_CACHE_PORT=11211
# END-DEPRECATED
APP_VERSION=2.3.0

$ sed '/# BEGIN-DEPRECATED/,/# END-DEPRECATED/d' build.env
APP_NAME=checkout-service
APP_VERSION=2.3.0
# deletes everything from the start marker through the end marker, inclusive,
# without needing to know the exact line numbers
```

**5. Basic `awk` field printing — extracting hostname and IP from a server inventory**
```bash
$ cat inventory.txt
web01    10.0.1.11   us-east-1a   running
web02    10.0.1.12   us-east-1b   running
db01     10.0.2.20   us-east-1a   running
cache01  10.0.3.5    us-east-1c   stopped

$ awk '{print $1, $2}' inventory.txt
web01 10.0.1.11
web02 10.0.1.12
db01 10.0.2.20
cache01 10.0.3.5
# whitespace-based splitting handles the uneven column alignment automatically —
# `cut -d' '` would break here because the gaps aren't a fixed single space
```

**6. `awk -F` — parsing `/etc/passwd`-style colon-delimited data**
```bash
$ cat /etc/passwd | tail -4
appsvc:x:1001:1001::/home/appsvc:/bin/bash
deploy:x:1002:1002::/home/deploy:/bin/bash
nginx:x:112:118:nginx web server:/var/lib/nginx:/usr/sbin/nologin
postgres:x:113:119::/var/lib/postgresql:/bin/bash

$ awk -F: '{print $1":"$NF}' /etc/passwd | tail -4
appsvc:/bin/bash
deploy:/bin/bash
nginx:/usr/sbin/nologin
postgres:/bin/bash
# $NF grabs the last field (the shell) regardless of how many colons precede it —
# handy since the GECOS field ($5) is often empty, shifting nothing but still safe via $NF
```

**7. `awk` aggregation with `BEGIN`/`END` — summing bytes transferred from an access log**
```bash
$ cat access.log
10.4.0.12 - - [08/Aug/2026:10:01:02] "GET /api/orders HTTP/1.1" 200 4821
10.4.0.15 - - [08/Aug/2026:10:01:05] "GET /api/health HTTP/1.1" 200 124
10.4.0.12 - - [08/Aug/2026:10:01:09] "POST /api/orders HTTP/1.1" 201 892
10.4.0.19 - - [08/Aug/2026:10:01:14] "GET /api/orders HTTP/1.1" 500 310

$ awk '{sum += $NF} END {print "Total bytes:", sum}' access.log
Total bytes: 6147

$ awk '$(NF-1) == 500 {count++} END {print "5xx count:", count+0}' access.log
5xx count: 1
# $(NF-1) is the status code field; count+0 forces 0 (not empty) if nothing matched
```

**8. `awk` numeric field filtering — hostnames where CPU% exceeds 80 in a monitoring CSV**
```bash
$ cat cpu_report.csv
host,cpu_pct,mem_pct
web01,42.1,55.0
web02,88.7,61.2
db01,93.4,74.8
cache01,15.0,20.3

$ awk -F, 'NR>1 && $2 > 80 {print $1, $2}' cpu_report.csv
web02 88.7
db01 93.4
# NR>1 skips the header row; $2 > 80 compares the string field numerically —
# no cast needed, awk coerces "88.7" to a number automatically
```

**9. Combined pipeline — total bytes served per unique IP, sorted descending (production-flavored)**
```bash
$ cat nginx_access.log
10.4.0.12 - - [08/Aug/2026:11:00:01] "GET /api/orders HTTP/1.1" 200 4821
10.4.0.15 - - [08/Aug/2026:11:00:02] "GET /api/health HTTP/1.1" 200 124
10.4.0.12 - - [08/Aug/2026:11:00:03] "GET /api/orders HTTP/1.1" 200 4790
10.4.0.19 - - [08/Aug/2026:11:00:04] "GET /api/orders HTTP/1.1" 500 310
10.4.0.12 - - [08/Aug/2026:11:00:05] "POST /api/checkout HTTP/1.1" 201 998

$ grep ' 200 \| 201 ' nginx_access.log | awk '{bytes[$1] += $NF} END {for (ip in bytes) print bytes[ip], ip}' | sort -rn
10609 10.4.0.12
124 10.4.0.15
# grep filters to only successful responses (2xx), awk buckets bytes per source
# IP into an associative array, END prints the totals, sort -rn orders by bytes
# descending — this exact chain is a very common "find your top bandwidth consumer" ask
```

**10. `awk printf` — reformatting monitoring output into an aligned report**
```bash
$ awk -F, 'NR>1 {printf "%-10s CPU:%6.1f%%  MEM:%6.1f%%\n", $1, $2, $3}' cpu_report.csv
web01      CPU:  42.1%  MEM:  55.0%
web02      CPU:  88.7%  MEM:  61.2%
db01       CPU:  93.4%  MEM:  74.8%
cache01    CPU:  15.0%  MEM:  20.3%
# printf gives fixed-width, aligned columns that plain `print` (space-separated) can't
```

## Practice Questions

1. Write a `sed` one-liner to replace every occurrence of `staging.internal` with `prod.internal` in a config file, printing the result to stdout without modifying the file.
2. You run `sed -i 's/foo/bar/' notes.txt` on your Mac and get `sed: 1: "notes.txt": invalid command code n`. What's happening, and what's the correct command on macOS?
3. Given a file with mixed comment lines (`#...`) and real config lines, write a single `sed` command that removes both comment lines and blank lines in one invocation.
4. Write a `sed` command that deletes everything between a line containing `START-BLOCK` and a line containing `END-BLOCK`, inclusive, without knowing the line numbers in advance.
5. Given a CSV file `sales.csv` with columns `region,rep,amount`, write an `awk` one-liner that prints only the `rep` and `amount` columns for rows where `amount` exceeds 10000.
6. Why does `awk '{print $1, $3}' server_status.txt` handle a file with inconsistent (multiple/variable) spaces between columns correctly, while `cut -d' ' -f1,3` on the same file often gives wrong or empty fields?
7. Write an `awk` one-liner that counts how many lines in an access log have a `5xx` status code (assume status is the second-to-last whitespace-separated field), using `BEGIN`/`END` as appropriate.
8. You need the average response size from an access log where size is the last field. Write the `awk` one-liner (sum divided by count), and explain what `NR` gives you at the `END` block.
9. Design a single pipeline (`grep`/`awk`/`sort`/etc.) that finds the top 3 IP addresses by total bytes transferred from an nginx access log.
10. A teammate uses `sed 's/foo/bar/g'` when they only wanted to replace the first occurrence on lines with multiple matches. What flag should they have used instead of `g`, and how would they replace only the *second* occurrence specifically?

## Real Interview Questions (Company-Attributed)

- "What is the purpose of the `sed` command?" — asked at *Morgan Stanley*
- "What is the difference between `find` and `sed`?" — asked at *Synechron*

## Interview Key Points

- **`sed -i` GNU vs BSD is the #1 portability trap** — GNU allows bare `-i` or `-i.bak`; BSD/macOS *requires* an explicit suffix argument, even an empty one (`-i ''`), or it misparses your script as the suffix and errors out. Know this cold; it's asked constantly.
- **`awk`'s default whitespace field-splitting is its core advantage over `cut`** — `cut` needs a single literal delimiter and breaks on repeated/variable spaces (common in `ps`, `df`, hand-aligned logs); `awk`'s default `FS` treats any run of whitespace as one separator.
- **`BEGIN`/`END` bookend the stream**: `BEGIN` runs once before any line is read (setup — set `FS`, init counters), `END` runs once after the last line (teardown — print totals/aggregates). Neither matches an actual input line.
- **`awk` auto-coerces strings to numbers in numeric context** — `$3 > 80` works directly on a CSV field with no explicit cast, unlike most shell tooling that needs `[[ ... ]]`/`bc`/`expr` gymnastics.
- **The decision rule interviewers want to hear**: `grep` = filter which lines you see, no transformation; `sed` = line-oriented find/replace or line/range deletion; `awk` = column-oriented extraction, filtering by field, and aggregation/math across rows.
- **`sed -n '/pattern/p'` vs plain `grep 'pattern'`** — functionally similar for basic filtering, but interviewers probe whether you know `sed` *can* do this (`-n` suppresses auto-print, `p` explicitly prints matches) even though `grep` is the simpler, idiomatic tool for pure filtering.
- **`g` flag and numeric occurrence flags are distinct** — `s/pat/rep/g` replaces all matches per line; `s/pat/rep/2` replaces only the Nth match; forgetting `g` and assuming all-line replacement is a classic silent-bug source in shell scripts.
- **Real interview asks are pipeline-shaped, not trivia-shaped** — expect "sum column X," "count lines matching Y," "top N by column Z," combining `grep | awk | sort`, over toy-trivia definitions of what each flag does.
