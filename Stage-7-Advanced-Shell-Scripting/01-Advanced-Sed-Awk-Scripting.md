# Advanced sed/awk Scripting — CSV Manipulation & Log Automation

The two tools that turn "I have a giant text/CSV/log file" into "I have exactly the data I need" — the single highest-leverage skill for platform/SRE automation work.

## Explanation

### `awk` — field/record processing engine

awk reads input **record by record** (default: one line = one record) and splits each record into **fields** (default: whitespace-separated) accessible as `$1`, `$2`, ... `$NF` (last field), with `$0` meaning the whole record. Its program structure is `pattern { action }` pairs:

```awk
awk 'pattern1 { action1 } pattern2 { action2 }' file
```

- `-F','` sets the **input field separator** (crucial for CSV — default whitespace splitting breaks on comma-separated data).
- `OFS` (output field separator, default single space) controls what gets used **when you rebuild `$0`** by reassigning a field or printing fields comma-separated with `print $1, $2` — set it via `BEGIN{OFS=","}` or `-v OFS=','`.
- `BEGIN{...}` runs once before any input is read (init counters, print headers). `END{...}` runs once after all input is consumed (print totals/summaries).
- `NR` = current record (line) number overall; `NF` = number of fields in the current record; `FNR` = record number within the *current file* (differs from `NR` when processing multiple files).
- **Associative arrays** (`arr[key]+=value`) are how you do group-by/aggregation — awk arrays are just hash maps, keys can be any string (e.g., a hostname, a region, an IP).
- Patterns can be regexes (`/failed/ {...}`), field comparisons (`$3 == "failed"`), ranges, or empty (`{...}` runs on every line).

### `sed` — stream editor

sed applies **line-by-line editing commands** to a stream, most commonly substitution: `s/pattern/replacement/flags`. Key mechanics:

- `-i` edits the file **in place** (no in-place edit without it — plain `sed 's/a/b/' file` only prints to stdout, the file is untouched).
- `-e` lets you chain **multiple separate commands** in one invocation: `sed -e 'cmd1' -e 'cmd2' file`. Equivalent to a `;`-separated single `-e`, or a `-f script.sed` file with one command per line — useful when the script gets long enough to be unreadable inline.
- Line addressing: `N` (line number), `$` (last line), `/regex/` (lines matching), `N,M` (range), `/start/,/end/` (regex range) — any of these can prefix a command to restrict where it applies.
- Common commands beyond `s///`: `d` (delete matched lines), `p` (print — usually paired with `-n` to suppress default auto-print), `a`/`i` (append/insert text).
- Flags on `s///`: `g` (replace all occurrences per line, not just the first), `i`/`I` (case-insensitive), a number (replace only the Nth occurrence).

### Which one should you actually use? (Decision rule)

| Task shape | Use | Why |
|---|---|---|
| Extracting/reordering **columns**, doing **math**, aggregating, per-field conditional logic | **`awk`** | awk natively understands fields/records; sed has no concept of "column 3" |
| Find-and-replace text, deleting/inserting specific lines, in-place file edits | **`sed`** | Purpose-built for line-oriented text transformation; awk *can* do this but it's clunkier |
| Just need to know **which lines match** a pattern (no transformation) | **`grep`** | Simplest, fastest tool for pure matching — don't reach for awk/sed just to filter lines with no field logic |
| Complex multi-step transformation (parse + aggregate + format) | **`awk` alone, or `awk` piped with `sort`/`sed`** | awk can do 90% of it in one pass; reserve sed for a final light text cleanup step |

**Bottom line: if the task is about columns or arithmetic, reach for `awk`; if it's about substituting or trimming text by line, reach for `sed`; chain them (`sed | awk` or `awk | sort`) rather than forcing one tool to do the other's job.**

A quick regex note: sed (by default) and grep (by default) use **BRE** (Basic Regular Expressions — `+`, `?`, `|`, `()` need backslash-escaping to be "special"); `sed -E` / `grep -E` switch to **ERE** where those are special unescaped. awk's regex engine is ERE-like by default, no flag needed. Full BRE-vs-ERE mechanics are covered in depth in the next file — this file uses ERE-style (`-E`) patterns where regex is needed, and ERE (`\{1,3\}` in BRE-mode sed) where it isn't.

## Hands-On Examples

All CSV examples use this sample inventory file, `servers.csv`:
```bash
$ cat servers.csv
hostname,region,status,cpu_pct,disk_gb
web-01,us-east,running,45,120
web-02,us-east,failed,12,80
db-01,us-west,running,78,540
db-02,us-west,failed,90,600
cache-01,eu-west,running,33,40
web-03,us-east,running,55,95
```

**1. Extracting & reordering specific columns**
```bash
$ awk -F',' 'BEGIN{OFS=","} {print $1, $5, $3}' servers.csv
hostname,disk_gb,status
web-01,120,running
web-02,80,failed
db-01,540,running
db-02,600,failed
cache-01,40,running
web-03,95,running
```
`-F','` splits on comma; `OFS=","` controls the separator awk uses when it prints multiple comma-joined fields with `print $1, $5, $3`. Notice the header row flows through the same logic automatically — `$1`/`$5`/`$3` on the header line are just the column-name strings.

**2. Filtering CSV rows by column value (string) and by threshold (numeric)**
```bash
$ awk -F',' 'NR==1 || $3=="failed"' servers.csv
hostname,region,status,cpu_pct,disk_gb
web-02,us-east,failed,12,80
db-02,us-west,failed,90,600

$ awk -F',' 'NR==1 || $4>70' servers.csv
hostname,region,status,cpu_pct,disk_gb
db-01,us-west,running,78,540
db-02,us-west,failed,90,600
```
`NR==1 || <condition>` is the standard awk idiom for "always keep the header, then filter the rest" — a pattern with no `{action}` block just prints `$0` when true, so this works as a one-liner filter with zero explicit `print`. `$4>70` is a **numeric** comparison — awk auto-detects that `$4` looks like a number, no cast needed (unlike shell `[ ]`).

**3. Summing a numeric column, and group-by aggregation with an associative array**
```bash
$ awk -F',' 'NR>1{sum+=$5} END{print "Total disk_gb:", sum}' servers.csv
Total disk_gb: 1475

$ awk -F',' 'NR>1{by_region[$2]+=$5} END{for (r in by_region) printf "%-10s %d\n", r, by_region[r]}' servers.csv | sort
eu-west    40
us-east    295
us-west    1140
```
The second command is the workhorse pattern for ops reporting: `by_region[$2]+=$5` uses the **region column as an array key** and accumulates disk usage per key — this is a real group-by/aggregate, the awk equivalent of SQL's `GROUP BY region SUM(disk_gb)`. `for (r in array)` iteration order is **not guaranteed**, so pipe to `sort` if you need deterministic/alphabetical output (very commonly forgotten, and a real interview trap).

**4. Adding a computed/derived column**
```bash
$ awk -F',' 'BEGIN{OFS=","} NR==1{print $0,"cpu_flag"; next} {flag=($4>70)?"HIGH":"OK"; print $0, flag}' servers.csv
hostname,region,status,cpu_pct,disk_gb,cpu_flag
web-01,us-east,running,45,120,OK
web-02,us-east,failed,12,80,OK
db-01,us-west,running,78,540,HIGH
db-02,us-west,failed,90,600,HIGH
cache-01,eu-west,running,33,40,OK
web-03,us-east,running,55,95,OK
```
`next` skips the rest of the script for the header row (so it just gets the literal `cpu_flag` label appended, not a computed flag). The ternary `(cond)?a:b` computes a new field per row and `print $0, flag` appends it — this is exactly how you'd bolt an alert/status column onto raw metrics before shipping to a report or dashboard.

**5. In-place find-and-replace across multiple files with `sed -i`**
```bash
$ grep -l "region=us-east" *.conf
app1.conf
app2.conf

$ sed -i 's/region=us-east/region=us-east-1/' *.conf

$ grep "region=" *.conf
app1.conf:region=us-east-1
app2.conf:region=us-east-1
app3.conf:region=us-west-2
```
`sed -i` rewrites every matched file directly — `*.conf` glob expansion means this hits every file in one command, standard for a "rename this config key everywhere" ops task.

**The macOS/BSD caveat (a real, common gotcha):** GNU sed (Linux) takes `-i` with no argument for "no backup." BSD/macOS sed requires an explicit (even if empty) suffix argument immediately after `-i`:
```bash
# Linux (GNU sed) — works:
$ sed -i 's/foo/bar/' file.txt

# macOS (BSD sed) — the line above FAILS with:
sed: 1: "file.txt": extra characters at the end of d command
# because BSD sed swallows 's/foo/bar/' as the backup-suffix argument to -i

# macOS-correct (empty string = no backup file):
$ sed -i '' 's/foo/bar/' file.txt

# Portable across both (creates a .bak backup on both platforms):
$ sed -i.bak 's/foo/bar/' file.txt
```
This is a genuinely common "why does my script work on my Linux CI but fail on a teammate's Mac" bug — know it cold.

**6. Multi-command sed script for a realistic log-cleanup task**

Raw application log has ANSI color codes, embedded IPs that need redacting, and trailing whitespace:
```bash
$ cat -A raw.log | head -2
2026-08-08 10:15:02 ^[[32mINFO^[[0m Request from 203.0.113.45 succeeded   $
2026-08-08 10:15:05 ^[[31mERROR^[[0m Request from 198.51.100.12 failed$
```
(`cat -A` reveals the `^[` = ESC character driving the color codes, and `$` marking trailing spaces before end-of-line.)
```bash
$ sed -e 's/\x1b\[[0-9;]*m//g' \
      -e 's/[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/<redacted-ip>/g' \
      -e 's/[[:space:]]*$//' raw.log > clean.log

$ cat clean.log
2026-08-08 10:15:02 INFO Request from <redacted-ip> succeeded
2026-08-08 10:15:05 ERROR Request from <redacted-ip> failed
```
Three independent transformations chained with three `-e` flags in a single pass. The same three commands as a script file (`cleanup.sed`, one command per line) are cleaner once a script grows past 2-3 commands: `sed -f cleanup.sed raw.log > clean.log`. Note `\{1,3\}` is BRE syntax — in default (non `-E`) sed, the interval quantifier braces must be backslash-escaped.

**7. Extracting/transforming specific lines: blank lines, comments, line ranges**
```bash
$ cat -n nginx.conf
     1  server {
     2      listen 80;
     3
     4      # redirect all traffic to https
     5      return 301 https://$host$request_uri;
     6
     7  }

$ sed '/^$/d' nginx.conf                    # delete blank lines
server {
    listen 80;
    # redirect all traffic to https
    return 301 https://$host$request_uri;
}

$ sed '/^[[:space:]]*#/d' nginx.conf        # delete comment lines (optional leading whitespace then #)
server {
    listen 80;

    return 301 https://$host$request_uri;

}

$ sed -n '2,4p' nginx.conf                  # extract only lines 2-4
    listen 80;

    # redirect all traffic to https

$ sed -e '/^$/d' -e '/^[[:space:]]*#/d' nginx.conf   # both cleanups combined
server {
    listen 80;
    return 301 https://$host$request_uri;
}
```
`-n` combined with `p` suppresses sed's default "print every line" behavior so *only* explicitly printed lines show — the standard way to extract a line range instead of transforming the whole file.

**8. Combined awk + sed real ops pipeline: top IPs by request count from an access log**
```bash
$ cat access.log
203.0.113.45 - - [08/Aug/2026:10:15:02 +0000] "GET /api/health HTTP/1.1" 200 15
198.51.100.12 - - [08/Aug/2026:10:15:03 +0000] "GET /api/users HTTP/1.1" 500 320
203.0.113.45 - - [08/Aug/2026:10:15:05 +0000] "GET /api/orders HTTP/1.1" 200 812
203.0.113.99 - - [08/Aug/2026:10:15:06 +0000] "POST /api/login HTTP/1.1" 401 55
198.51.100.12 - - [08/Aug/2026:10:15:08 +0000] "GET /api/users HTTP/1.1" 200 300
203.0.113.45 - - [08/Aug/2026:10:15:09 +0000] "GET /api/health HTTP/1.1" 200 15

$ sed -E 's/\[|\]//g' access.log | awk '{ips[$1]++} END{for (ip in ips) printf "%d %s\n", ips[ip], ip}' | sort -rn
3 203.0.113.45
2 198.51.100.12
1 203.0.113.99
```
`sed -E 's/\[|\]//g'` (ERE mode, `|` for alternation without escaping) strips the `[`/`]` around the timestamp for cleaner downstream parsing; `awk` then aggregates counts per IP (`$1`, since Common Log Format's IP is always field 1 with default whitespace splitting); `sort -rn` ranks numerically descending. This exact shape — light `sed` normalization feeding an `awk` aggregation feeding `sort` — is one of the most common real ops one-liners you'll write for log triage.

A companion query on the same log — 5xx errors by IP, using awk's field access on the unquoted status-code field (`$9`, since the quoted `"METHOD /path HTTP/1.1"` splits into 3 whitespace-separated fields):
```bash
$ awk '$9 ~ /^5/ {print $1}' access.log | sort | uniq -c | sort -rn
      1 198.51.100.12
```

## Practice Questions

1. Given a CSV with columns `hostname,region,status,cpu_pct,disk_gb`, write an `awk` one-liner that prints only `hostname` and `disk_gb`, comma-separated, for rows where `status` is `failed`.
2. Why does `awk '{print $1, $2}' file.csv` fail to split correctly on a comma-separated file, and what's the fix?
3. Write an `awk` command that computes the total and the average of a numeric column across all rows (excluding the header).
4. Explain how you'd use an awk associative array to produce a "sum of disk_gb grouped by region" report from `servers.csv`. Why is the output order not guaranteed, and how do you fix that?
5. What's the difference between `sed 's/foo/bar/' file` and `sed -i 's/foo/bar/' file`? What happens if you forget `-i` when the intent was to modify the file?
6. A script using `sed -i 's/x/y/' file.txt` works fine on the team's Linux CI but fails on a colleague's Mac with `extra characters at the end of d command`. What's happening, and what's the portable fix?
7. Write a `sed` command (or short script) that removes all blank lines AND all lines starting with `#` from a config file, in one pass.
8. You need to parse an nginx access log and print the top 5 IPs by request count. Walk through the `awk`/`sort` pipeline you'd use and explain each stage.
9. When would you choose `awk` over `sed` (and vice versa) for a text-processing task? Give one example task that's clearly awk's job and one that's clearly sed's.
10. What does `NR==1 || $4>70` do as an awk program with no explicit `print`/`{}` action block, and why does that work?

## Real Interview Questions (Company-Attributed)

- "Write a script to search a log file for the patterns 'error' and 'warning', storing error lines in one file and warning lines in another, with the filename passed as an argument." — asked at *EPAM*
- "Using `sed`, how do you remove the first and last line of a file?" — asked at *Morgan Stanley*
- "Write a script to find a particular name/word in a file and replace it with another word." — asked at *Sigmoid*
- "Write a script to find the first occurrence of a pattern in a file and extract the full matching line." — asked at *Sigmoid*
- "Given a real-time app log with lines like `Connection established from: <IP>`, write a script that returns all unique IP addresses and their total count." — asked at *Sigmoid*
- "Write a script that reads a log with ERROR/INFO lines and raises an alert if the same error message occurs more than 3 times." — asked at *Sigmoid*
- "Write a Bash script for log analysis." — asked at *an unnamed company (via community-sourced interview notes)*

## Interview Key Points

- **Field splitting is awk's superpower, sed has none** — the moment a task involves "column N" or "sum this field," it's an awk task, not a sed task; interviewers use this to check you're not forcing the wrong tool.
- **`-F','` + `OFS`** is the CSV-processing combo that comes up constantly — know that `OFS` only applies to output you *construct* via `print $1,$2,...` or by reassigning a field, not automatically to `$0` unless you also modify `$0`.
- **`awk` associative arrays are the group-by mechanism** — `arr[$2]+=$5` is the single most-tested "aggregate by category" pattern; also know that iteration order over `for (k in arr)` is unordered, so senior answers pipe to `sort`.
- **`sed -i` in-place editing has NO built-in dry-run** — always mention testing without `-i` first (or with `-i.bak`) on production files; this is a "do you have good habits" signal, not just a syntax question.
- **The macOS/BSD `sed -i` argument difference is a classic real-world portability bug** — know the exact symptom (`extra characters at the end of d command`) and the fix (`sed -i '' ...` on BSD, or `sed -i.bak ...` for a cross-platform-safe version).
- **`NR==1 || condition`** is the idiomatic awk "keep header + filter data rows" pattern — recognize and use it instead of writing a separate header-print step.
- Multiple `-e` flags (or a `-f script.sed` file) let sed run several transformations in a single pass over the data — more efficient and more readable than chaining multiple separate `sed | sed | sed` pipeline stages.
- The classic combined pipeline — `sed` (light text cleanup) → `awk` (aggregate/compute) → `sort` (rank) — is the real shape of most log-analysis one-liners you'll be asked to produce live in an interview or on-call.
