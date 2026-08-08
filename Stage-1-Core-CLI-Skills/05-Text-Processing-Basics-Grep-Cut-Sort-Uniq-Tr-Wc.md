# Text Processing Basics: `grep`, `cut`, `sort`, `uniq`, `tr`, `wc`

The six tools you reach for before `awk`/`sed` ever enter the picture — filtering, slicing, ordering, deduping, transforming, and counting text, which is most of what incident response and log analysis actually is.

## Explanation

### `grep` — pattern search and filtering

`grep PATTERN file` prints every line matching `PATTERN`; everything about `grep` is really about controlling *what counts as a match* and *what gets printed*.

- `-i` — case-insensitive match (`grep -i error` matches `ERROR`, `Error`, `error`).
- `-v` — invert the match: print lines that **don't** match. The standard way to strip noise (health checks, heartbeats, debug spam) out of a log before reading it.
- `-c` — print a count of matching *lines*, not the lines themselves. Note: it counts matching lines, not total occurrences — a line with two matches still counts as `1`.
- `-n` — prefix each output line with its line number in the source file. Useful for jumping straight to a spot in a file with `sed -n '412p' file` or an editor afterward.
- `-r` / `-R` — recurse into a directory searching every file (`-R` also follows symlinks, `-r` doesn't). Essential when errors could be in any of several log files and you don't know which one.
- `-l` — print only the **filenames** that contain at least one match, not the matching lines themselves. Pairs naturally with `-r` — "which of these 40 log files even mention this error."
- `-w` — match whole words only. `grep 500 access.log` also matches `1500` and `5001`; `grep -w 500` matches only a standalone `500` token.
- `-o` — print only the **matched text itself**, one match per output line, instead of the whole containing line. This is the flag that turns `grep` into an extraction tool rather than just a filter — critical for pulling IPs, status codes, or IDs out of log lines to feed into the next stage of a pipeline (`sort`, `uniq -c`, etc.).
- `-E` — extended regex (ERE): lets you use `+`, `?`, `|`, `()`, `{}` directly without backslash-escaping them. Plain `grep` uses basic regex (BRE), where those same characters are literal and need a backslash (`\+`, `\|`, `\(\)`) to gain their special meaning. `grep -E` is equivalent to `egrep` (deprecated, avoid it). In practice: reach for `-E` the moment you need alternation (`|`) or `{n,m}` repetition — trying to write `ERROR|WARN` under plain BRE grep either fails or requires `\|`, which is a common tripping point.
- `-A N` / `-B N` / `-C N` — print `N` lines of context **A**fter / **B**efore / around (**C**ontext, both sides) each match. This is what actually makes `grep` usable for reading logs around an error, instead of just spitting an isolated line with no surrounding stack trace or preceding request info.

### `cut` — extracting fields or character ranges

`cut` slices each line by delimiter or by character position — cheap and fast for clean, fixed-format data.

- `-d` — the field delimiter. **Must be a single literal character** (`,`, `:`, `|`, tab). You cannot give `cut` a delimiter of "one or more spaces" or a multi-character delimiter — that's a hard limitation, not a missing flag you forgot.
- `-f` — which field(s) to keep: a single number (`-f2`), a range (`-f1-3`), or a comma list (`-f1,3,5`).
- `-c` — select by **character position** instead of field, e.g. `-c1-3` to grab the first three characters of every line (handy for fixed-width data, like pulling a log level that always occupies columns 1-5).

The limitation worth internalizing for interviews: `cut -d' '` treats *each individual space* as a field boundary, so two consecutive spaces produce an **empty field** in between — output like `ps aux` or `df -h`, which pad columns with variable runs of whitespace, breaks `cut` badly (`-f2` might land on nothing, or shift depending on how many spaces happened to appear). `cut` has no "squeeze repeated delimiters" mode. That's exactly the gap `awk` fills — `awk '{print $2}'` treats any run of whitespace as one delimiter automatically (covered in file 6). Rule of thumb: `cut` for clean, single-character, fixed-delimiter data (CSV, `/etc/passwd`, colon/pipe-separated exports); `awk` the moment the delimiter is inconsistent whitespace or you need any conditional logic.

### `sort` — ordering lines

Default `sort` orders lines **lexicographically** (dictionary/byte order), which is the single most common gotcha: `"10"` sorts *before* `"9"` under default sort, because `sort` compares character-by-character and `'1'` < `'9'` as characters — it has no idea these are numbers unless told.

- `-n` — numeric sort: compares the actual numeric value, so `9` correctly sorts before `10`.
- `-r` — reverse the sort order (descending instead of ascending).
- `-k` — sort by a specific field/column instead of the whole line (`-k2` sorts by the 2nd field; `-k2,2` sorts by *only* the 2nd field, important when later fields would otherwise break ties differently than intended).
- `-t` — set the field delimiter `sort` uses to determine columns for `-k` (mirrors `cut -d`; default is whitespace).
- `-u` — unique: dedupes lines **and** sorts in the same pass — a single-command alternative to `sort | uniq` when you don't need `uniq`'s count/duplicate-only modes.
- `-h` — human-numeric sort: understands suffixes like `1K`, `2M`, `3G` and sorts by actual magnitude — built specifically for output like `du -h` or `ls -lh` where `-n` alone would sort the strings, not the sizes.

### `uniq` — collapsing duplicate lines (adjacent only)

This is the single most-tested gotcha in this whole topic: **`uniq` only removes or collapses ADJACENT duplicate lines.** It does not scan the whole file for duplicates — it walks line by line and only compares each line to the *immediately preceding* one. If two identical lines are separated by anything else in between, `uniq` treats them as two distinct, unrelated lines and keeps both.

That means `uniq` is almost always used as `sort file | uniq`, never `uniq file` alone on unsorted input — sorting first guarantees every group of identical lines becomes physically adjacent, which is the only condition under which `uniq` actually dedupes correctly across an entire file.

- `-c` — prefix each output line with a count of how many times it occurred consecutively. This is the engine behind the extremely common `sort | uniq -c | sort -rn` pattern: sort to group duplicates together, `uniq -c` to count each group, `sort -rn` to rank by count descending — "top N most frequent lines" (status codes, IPs, error messages, whatever).
- `-d` — print only lines that **were** duplicated (occurred more than once).
- `-u` — print only lines that appear **exactly once** (the inverse of `-d`) — useful for finding one-off/rare events, like a single anomalous error type in a sea of repeats.

### `tr` — character-level translate / delete / squeeze

`tr` is the odd one out mechanically: it reads only from **standard input**, never accepts a filename as an argument the way `grep file` or `cut file` do. You must pipe or redirect into it (`cat file | tr ...` or `tr ... < file`) — passing a filename as an operand is a common beginner mistake that just hangs waiting on stdin instead.

- `tr 'a-z' 'A-Z'` — translate: maps each character in set 1 to the corresponding character in set 2, positionally. Classic use: case conversion.
- `-d` — delete every character in the given set entirely, no replacement. The textbook production use: `tr -d '\r'` to strip trailing carriage returns from a file that originated on Windows (CRLF line endings), the shell-native alternative to `dos2unix`.
- `-s` — squeeze: collapse consecutive **repeated** characters from the given set down to a single instance. `tr -s ' '` turns any run of multiple spaces into exactly one space — handy for normalizing ragged, human-typed, or padded output before further processing (though for genuinely tabular data, `awk`'s automatic whitespace handling is usually the better fix).
- `-c` — complement the set: operate on every character **NOT** in the given set instead of the ones listed. `tr -cd '0-9\n'` deletes everything that *isn't* a digit or newline — a quick way to strip a file down to just numbers.

### `wc` — counting lines, words, characters, bytes

Bare `wc file` prints all three core counts at once: lines, words, bytes (in that order), followed by the filename.

- `-l` — lines only. By far the most common flag in pipelines: `grep ERROR file | wc -l` to get a raw count of matching lines.
- `-w` — words only (whitespace-delimited tokens).
- `-c` — bytes.
- `-m` — characters. Differs from `-c` on multi-byte UTF-8 content (e.g. accented characters, emoji, non-Latin scripts) where one *character* can occupy several *bytes* — `-c` counts bytes, `-m` counts actual characters, and they diverge the moment the file isn't pure ASCII.

### Which tool for which job? (Decision rule)

| Task | Tool |
|---|---|
| Extract a specific column from clean, fixed-delimiter data | `cut -d -f` (or `awk '{print $N}'` if the delimiter is ragged whitespace) |
| Filter rows matching (or excluding) a pattern | `grep` (`-v` to exclude) |
| Extract just the matched substring, not the whole line | `grep -o` |
| Dedupe lines / count occurrences of each distinct line | `sort \| uniq` / `sort \| uniq -c` |
| Rank by frequency ("top N") | `sort \| uniq -c \| sort -rn \| head -N` |
| Order rows numerically or by a specific column | `sort -n` / `sort -k` |
| Case-convert, strip, or squeeze specific characters | `tr` |
| Count lines/words/matches | `wc -l` / `wc -w` |

**Bottom line:** `cut` is fine as long as the data has a genuinely single-character, consistent delimiter — the moment the delimiter is inconsistent whitespace, or you need any conditional logic ("only print this field if that other field matches"), reach for `awk` instead (file 6 covers it).

## Hands-On Examples

**1. Basic `grep` filtering — finding ERROR lines in an application log**
```bash
$ cat app.log
2026-08-08 14:22:01 INFO  [OrderService] Order 48290 processed successfully
2026-08-08 14:22:03 ERROR [OrderService] Failed to process order 48291: connection timeout to payment-gateway
2026-08-08 14:22:04 INFO  [OrderService] Order 48292 processed successfully
2026-08-08 14:22:05 WARN  [InventoryService] Low stock for SKU-3321
2026-08-08 14:22:06 ERROR [PaymentService] Gateway timeout after 30000ms
2026-08-08 14:22:07 INFO  [OrderService] Order 48293 processed successfully

$ grep ERROR app.log
2026-08-08 14:22:03 ERROR [OrderService] Failed to process order 48291: connection timeout to payment-gateway
2026-08-08 14:22:06 ERROR [PaymentService] Gateway timeout after 30000ms

$ grep -in "error" app.log
2:2026-08-08 14:22:03 ERROR [OrderService] Failed to process order 48291: connection timeout to payment-gateway
5:2026-08-08 14:22:06 ERROR [PaymentService] Gateway timeout after 30000ms
```
`-i` catches the pattern regardless of case; `-n` prefixes the real line numbers (`2:`, `5:`) from the original file, which is exactly what you want when someone asks "which line was the failure on."

**2. `grep -v` to exclude noise — filtering out health-check spam from an access log**
```bash
$ cat access.log
203.0.113.42 - - [08/Aug/2026:14:22:01 +0000] "GET /api/v2/orders HTTP/1.1" 200 512
10.0.0.5 - - [08/Aug/2026:14:22:02 +0000] "GET /healthz HTTP/1.1" 200 2
203.0.113.19 - - [08/Aug/2026:14:22:02 +0000] "POST /api/v2/checkout HTTP/1.1" 500 128
10.0.0.6 - - [08/Aug/2026:14:22:03 +0000] "GET /healthz HTTP/1.1" 200 2
198.51.100.7 - - [08/Aug/2026:14:22:04 +0000] "GET /api/v2/orders HTTP/1.1" 200 498
10.0.0.5 - - [08/Aug/2026:14:22:04 +0000] "GET /healthz HTTP/1.1" 200 2

$ grep -v "healthz" access.log
203.0.113.42 - - [08/Aug/2026:14:22:01 +0000] "GET /api/v2/orders HTTP/1.1" 200 512
203.0.113.19 - - [08/Aug/2026:14:22:02 +0000] "POST /api/v2/checkout HTTP/1.1" 500 128
198.51.100.7 - - [08/Aug/2026:14:22:04 +0000] "GET /api/v2/orders HTTP/1.1" 200 498
```
Kubernetes liveness/readiness probes (`kube-probe`) hit `/healthz` every few seconds and will drown out real traffic in a raw `tail`/`cat` read — `-v` is the standard first move before eyeballing a log manually.

**3. `grep -E` for multiple patterns, plus `-c`, `-o`, `-w`, and `-A`/`-B`/`-C` context**
```bash
$ grep -E "ERROR|WARN" app.log
2026-08-08 14:22:03 ERROR [OrderService] Failed to process order 48291: connection timeout to payment-gateway
2026-08-08 14:22:05 WARN  [InventoryService] Low stock for SKU-3321
2026-08-08 14:22:06 ERROR [PaymentService] Gateway timeout after 30000ms

$ grep -c ERROR app.log
2

$ grep -oE "order [0-9]+" app.log
order 48291
```
`-E` enables `|` for alternation without escaping; plain BRE `grep` would need `grep "ERROR\|WARN"` on GNU grep, and fails outright on stricter POSIX grep implementations. `-c` gives a raw count (`2` ERROR lines) instead of printing them. `-o` prints only the matched substring (`order 48291`), not the whole line — this is what feeds a clean value into `cut`/`sort`/`uniq` downstream instead of a whole noisy log line.
```bash
$ grep -w 500 access.log
203.0.113.19 - - [08/Aug/2026:14:22:02 +0000] "POST /api/v2/checkout HTTP/1.1" 500 128
```
`-w` matches the standalone token `500` and correctly skips the `498` and `512` byte-size fields nearby that merely contain the digits — without `-w`, a plain `grep 5` or careless pattern could false-positive on those.
```bash
$ grep -A2 -B1 "ERROR" app.log
2026-08-08 14:22:01 INFO  [OrderService] Order 48290 processed successfully
2026-08-08 14:22:03 ERROR [OrderService] Failed to process order 48291: connection timeout to payment-gateway
2026-08-08 14:22:04 INFO  [OrderService] Order 48292 processed successfully
2026-08-08 14:22:05 WARN  [InventoryService] Low stock for SKU-3321
--
2026-08-08 14:22:05 WARN  [InventoryService] Low stock for SKU-3321
2026-08-08 14:22:06 ERROR [PaymentService] Gateway timeout after 30000ms
2026-08-08 14:22:07 INFO  [OrderService] Order 48293 processed successfully
```
`-B1` shows 1 line before each ERROR, `-A2` shows 2 lines after — the `--` is `grep`'s own separator between non-contiguous match groups. This is the actual technique for reading "what led up to this error and what happened right after" without opening the whole file.
```bash
$ grep -rl "OutOfMemoryError" /var/log/myapp/
/var/log/myapp/worker-3.log
/var/log/myapp/worker-7.log
```
`-r` recurses through every file under the directory; `-l` prints only the filenames that matched instead of the matching lines — the fastest way to answer "which of these 12 log files even mention this error" before drilling into any one of them.

**4. Extracting columns from a CSV inventory file with `cut -d`/`-f`**
```bash
$ cat servers.csv
hostname,ip,region,role
web-01,10.0.1.11,us-east-1,web
web-02,10.0.1.12,us-east-1,web
db-01,10.0.2.21,us-east-1,database
cache-01,10.0.3.31,us-west-2,cache
web-03,10.0.1.13,us-west-2,web
lb-01,10.0.4.41,us-east-1,loadbalancer

$ cut -d',' -f1,3 servers.csv
hostname,region
web-01,us-east-1
web-02,us-east-1
db-01,us-east-1
cache-01,us-west-2
web-03,us-west-2
lb-01,us-east-1

$ cut -d',' -f1-3 servers.csv
hostname,ip,region
web-01,10.0.1.11,us-east-1
web-02,10.0.1.12,us-east-1
db-01,10.0.2.21,us-east-1
cache-01,10.0.3.31,us-west-2
web-03,10.0.1.13,us-west-2
lb-01,10.0.4.41,us-east-1
```
`-f1,3` is an explicit list (hostname + region, skipping ip); `-f1-3` is a range (hostname through region). Both use `,` as the single-character delimiter set with `-d`.
```bash
$ cut -c1-6 servers.csv
hostna
web-01
web-02
db-01,
cache-
web-03
lb-01,
```
`-c1-6` grabs raw character positions regardless of delimiters — note it doesn't respect field boundaries at all, which is why `db-01,` bleeds a trailing comma in; `-c` is for genuinely fixed-width data, not CSV.

**5. Parsing `/etc/passwd`-style colon-delimited data with `cut -d: -f1,7`**
```bash
$ cat /etc/passwd
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
deploy:x:1001:1001:Deploy User:/home/deploy:/bin/bash
svc-app:x:1002:1002:App Service Account:/home/svc-app:/usr/sbin/nologin
asha:x:1003:1003:Asha Kapoor:/home/asha:/bin/bash

$ cut -d: -f1,7 /etc/passwd
root:/bin/bash
daemon:/usr/sbin/nologin
deploy:/bin/bash
svc-app:/usr/sbin/nologin
asha:/bin/bash
```
Field 1 is the username, field 7 is the login shell — a one-liner audit for "which accounts actually have an interactive shell vs. `/usr/sbin/nologin`" (service accounts should almost always be the latter; a service account with `/bin/bash` is worth a security review).
```bash
$ cut -d: -f1,7 /etc/passwd | grep -v nologin
root:/bin/bash
deploy:/bin/bash
asha:/bin/bash
```
Chaining straight into `grep -v` narrows it to only the accounts with a real shell.

**6. Counting and ranking log entries with `sort | uniq -c`**
```bash
$ cat status_codes.txt
200
200
404
200
500
404
200
500
500
200

$ sort status_codes.txt | uniq -c
      1 404
      1 404
```
Wait — that's wrong on unsorted input. Compare `uniq -c` run directly against the raw file versus after `sort`:
```bash
$ uniq -c status_codes.txt
      2 200
      1 404
      1 200
      1 500
      1 404
      1 200
      2 500
      1 200
```
Unsorted, `uniq -c` only merges runs that happen to already be adjacent — `200` shows up as four separate groups because other codes interrupted the runs. Sort first:
```bash
$ sort status_codes.txt | uniq -c
      2 404
      5 200
      3 500

$ sort status_codes.txt | uniq -c | sort -rn
      5 200
      3 500
      2 404
```
Now every identical value is grouped correctly, `uniq -c` counts each group accurately, and the final `sort -rn` ranks by count descending — `200` is the most frequent status, `500` a concerning second at 3 occurrences.

**7. `sort -k`/`-n` on structured CSV data — ordering by a numeric column**
```bash
$ cat mem_usage.csv
web-01,12.4
web-02,45.2
db-01,120.7
cache-01,8.9
web-03,9.1
db-02,7.3

$ sort -t',' -k2 mem_usage.csv
db-01,120.7
cache-01,8.9
db-02,7.3
web-01,12.4
web-02,45.2
web-03,9.1
```
Default lexicographic sort on the memory column is wrong — `"120.7"` sorts before `"7.3"` and `"8.9"` because `'1'` < `'7'` < `'8'` as the first *character*, ignoring actual magnitude entirely.
```bash
$ sort -t',' -k2 -n mem_usage.csv
db-02,7.3
cache-01,8.9
web-03,9.1
web-01,12.4
web-02,45.2
db-01,120.7
```
`-t','` tells `sort` the field delimiter is a comma (mirroring `cut -d`); `-k2` says sort by the 2nd field; `-n` makes it numeric. Now `120.7` correctly lands last.
```bash
$ du -sh /var/log/* | sort -h
4.0K    /var/log/alternatives.log
128K    /var/log/dpkg.log
2.1M    /var/log/syslog
1.8G    /var/log/myapp
```
`-h` sorts human-readable sizes (`4.0K`, `128K`, `2.1M`, `1.8G`) by actual magnitude — plain `-n` would sort those strings wrong since it doesn't understand the `K`/`M`/`G` suffixes.
```bash
$ cat regions.txt
us-east-1
us-west-2
us-east-1
eu-west-1
us-west-2

$ sort -u regions.txt
eu-west-1
us-east-1
us-west-2
```
`-u` sorts and dedupes in a single pass — equivalent to `sort regions.txt | uniq` but one command instead of two.

**8. `tr` for case normalization and stripping unwanted characters**
```bash
$ echo "WEB-01.PROD.EXAMPLE.COM" | tr 'A-Z' 'a-z'
web-01.prod.example.com
```
Classic case normalization — useful when hostnames arrive inconsistently cased from different sources and need to match exactly for comparison or lookup.
```bash
$ file windows_export.csv
windows_export.csv: ASCII text, with CRLF line terminators

$ cat -A windows_export.csv | head -2
hostname,region^M$
web-01,us-east-1^M$

$ tr -d '\r' < windows_export.csv > unix_export.csv
$ file unix_export.csv
unix_export.csv: ASCII text
```
`^M` in `cat -A` output is the visible carriage return (`\r`) left over from a Windows-origin file — it causes silent bugs in scripts (a `\r` glued onto the last field of every line breaks exact-match comparisons). `tr -d '\r'` strips it — the shell-native `dos2unix` equivalent, since `tr` only reads stdin, hence the `< windows_export.csv` redirect rather than passing the filename as an argument.
```bash
$ echo "GET   /api/v2/orders     HTTP/1.1" | tr -s ' '
GET /api/v2/orders HTTP/1.1
```
`-s` (squeeze) collapses the repeated spaces down to single spaces — useful before further `cut`-based field splitting on ragged, human-formatted, or padded text.
```bash
$ echo "Order#48291-URGENT!!" | tr -cd '0-9\n'
48291
```
`-c` complements the set (everything that is *not* a digit or newline), combined with `-d` to delete all of it — leaves only the digits.

**9. `wc -l` for counting matches in a pipeline**
```bash
$ wc -l access.log
48213 access.log

$ grep -c "/api/v2/checkout" access.log
1847

$ grep "/api/v2/checkout" access.log | wc -l
1847
```
`grep -c` and `grep ... | wc -l` give the same answer here because every match is on its own line — `grep -c` is simpler and faster since it skips actually printing/piping the matched lines, but `wc -l` is the fallback when you're already mid-pipeline and the previous stage isn't a plain `grep` (e.g. after a `cut` or `awk` stage that `-c` can't apply to).
```bash
$ grep "/api/v2/checkout" access.log | grep " 500 " | wc -l
23
```
Chaining a second `grep` narrows it to specifically the checkout requests that returned a `500` — 23 failed checkouts out of 1847 total checkout requests, a concrete error-rate number pulled straight from raw logs.

**10. Combined pipeline — top 5 IPs hitting the server from an access log**
```bash
$ head -5 access.log
203.0.113.42 - - [08/Aug/2026:14:22:01 +0000] "GET /api/v2/orders HTTP/1.1" 200 512
203.0.113.42 - - [08/Aug/2026:14:22:02 +0000] "GET /api/v2/orders HTTP/1.1" 200 498
198.51.100.7 - - [08/Aug/2026:14:22:02 +0000] "POST /api/v2/checkout HTTP/1.1" 500 128
203.0.113.19 - - [08/Aug/2026:14:22:03 +0000] "GET /api/v2/orders HTTP/1.1" 200 512
198.51.100.7 - - [08/Aug/2026:14:22:04 +0000] "GET /api/v2/orders HTTP/1.1" 200 498

$ cut -d' ' -f1 access.log | sort | uniq -c | sort -rn | head -5
   6104 203.0.113.42
   3982 198.51.100.7
   2210 203.0.113.19
   1876 198.51.100.203
    944 192.0.2.88
```
Read left to right: `cut -d' ' -f1` pulls just the client IP (field 1 of the combined log format); `sort` groups identical IPs adjacently (the mandatory step before `uniq` can dedupe correctly — this file's central gotcha, applied for real); `uniq -c` collapses each group into a count; `sort -rn` ranks by that count descending; `head -5` trims to the top 5. `203.0.113.42` is the heaviest hitter at 6104 requests — worth checking against a rate-limit threshold or an abuse/bot signature before assuming it's legitimate traffic. The exact same shape of pipeline answers "top error messages," "top requested URLs," or "top usernames failing SSH login" by swapping what `cut`/`grep -o` extracts at the front.

## Practice Questions

1. You run `uniq -c` directly on a raw log file and the counts look wrong — duplicate lines are being reported as separate groups instead of one merged count. What's actually happening, and what's the one-word fix?
2. Extract just the 3rd and 5th columns from a CSV file where fields are comma-separated. Write the exact `cut` command.
3. Given a file of HTTP status codes (one per line, unsorted), write the pipeline that prints them ranked from most frequent to least frequent, with counts.
4. Why does `sort` on a column of plain integers put `"10"` before `"9"` by default? What flag fixes it, and why doesn't `cut` or `grep` have the same problem?
5. You need every username and login shell from `/etc/passwd`. Write the `cut` command, then explain why `cut -d' '` would not work on this file even though it also contains fixed structure.
6. What's the practical difference between `grep -c PATTERN file` and `grep PATTERN file | wc -l`? Are there situations where they'd give different numbers?
7. A colleague tries `tr 'a-z' 'A-Z' myfile.txt` and it just hangs with no output. What's wrong, and what are the two ways to fix the invocation?
8. Write a pipeline that finds the 5 IP addresses making the most requests in an nginx access log, using only `cut`, `sort`, `uniq`, and `head`.
9. You're asked to strip Windows-style line endings from a data export before loading it into a Unix tool that's failing to parse it. Which command do you reach for, and what's actually being removed?
10. Given `du -sh /var/log/*`, why would `sort -n` on that output produce a nonsensical ordering, and which flag actually sorts it correctly?

## Real Interview Questions (Company-Attributed)

- "Write a Unix command to find the ERROR keyword in a text file, case-insensitively." — asked at *Akamai*
- "In a log file there's a keyword `ERR` — give me the count of occurrences in the file." — asked at *an unnamed company (via community-sourced interview notes)*
- "Write a Bash command to get the total number of lines in a file." — asked at *an unnamed company (via community-sourced interview notes)*
- "How do you fetch/filter lines with a particular status code (e.g. 200) from a log file?" — asked at *IBM*
- "How do you find the 10th word in a file?" — asked at *Synechron*
- "How do you fetch/extract errors from log files?" — asked at *Morgan Stanley*

## Interview Key Points

- **`uniq` only collapses adjacent duplicates — it never scans the whole file.** Input must be sorted first (`sort file | uniq`) for it to dedupe correctly across the entire file; this is the single most common trap question in this topic and interviewers expect you to say it unprompted.
- **`sort` is lexicographic by default, not numeric** — `"9"` sorting after `"10"` is the classic gotcha; always reach for `-n` (or `-h` for human-readable sizes like `du -h` output) when the column is actually numbers.
- **`grep -o` turns a filter into an extractor** — instead of returning the whole matching line, it returns only the matched substring, which is what makes `grep` useful as the first stage of an extraction pipeline feeding `sort`/`uniq -c`.
- **`cut`'s delimiter must be a single literal character**, and it can't collapse repeated/variable whitespace — the moment field separation is ragged (like `ps aux` output) or needs conditional logic, that's the handoff point to `awk`.
- **`tr` reads stdin only** — it never takes a filename as an operand like `grep`/`cut`/`sort` do; you must pipe or redirect into it. A candidate typing `tr 'a-z' 'A-Z' file.txt` and being confused why it hangs is a genuine, common mistake worth knowing to diagnose instantly.
- **`sort | uniq -c | sort -rn | head -N` is the canonical "top N most frequent" pattern** — expect to write it from memory for status codes, IPs, error messages, or any other repeated field in a log.
- **`-A`/`-B`/`-C` on `grep` is what makes it usable for real incident reading** — an isolated error line without the surrounding request context is often useless; know these flags cold, not just the basic match flags.
- `wc -l` and `grep -c` often give the same number but measure different things (lines vs. matching lines) — they diverge once a pipeline stage before them can produce multiple matches per line or restructure the data, so don't treat them as interchangeable by definition, only by coincidence in the simple case.
