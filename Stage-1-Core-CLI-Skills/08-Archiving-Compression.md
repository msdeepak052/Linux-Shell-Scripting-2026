# Archiving & Compression (`tar`, `gzip`, `bzip2`, `xz`, `zip`/`unzip`)

Bundling files and shrinking them are two separate jobs on Linux — understanding which tool does which, and their speed/ratio trade-offs, is daily-driver knowledge for backups, log rotation, and shipping release artifacts.

## Explanation

### `tar` bundles, it does not compress

`tar` ("tape archive") walks a directory tree and concatenates files, directory structure, permissions, ownership, and timestamps into a single `.tar` file. On its own, a `.tar` is **not smaller** than the sum of its contents — it's just glued together. Compression is bolted on by piping the archive stream through a compressor, selected via a flag:

- `-z` → pipe through `gzip` → `.tar.gz` / `.tgz`
- `-j` → pipe through `bzip2` → `.tar.bz2`
- `-J` → pipe through `xz` → `.tar.xz`

Core action flags (pick exactly one primary action):
- `-c` create a new archive
- `-x` extract an archive
- `-t` list/table the contents **without extracting anything to disk** — always do this before extracting an archive from an untrusted or unfamiliar source, so you know what you're about to unpack (paths, whether it has a top-level directory, absolute paths, etc.)
- `-v` verbose (print each file as it's processed)
- `-f` the archive filename must follow — this is why `-f` is conventionally placed **last** in the flag cluster, immediately before the filename argument (`tar -czvf archive.tar.gz dir/`, never `tar -fczv archive.tar.gz dir/`)

Modern GNU `tar` can also auto-detect the compression format on extraction from the file's magic bytes even without `-z`/`-j`/`-J`, but relying on that in scripts is sloppy — always specify the flag explicitly so the command is self-documenting and portable to older `tar` builds.

`--exclude=PATTERN` skips matching files/directories while creating an archive (repeatable, useful for skipping `.git`, `node_modules`, log files, etc.). `tar -C /target/dir -xzf archive.tar.gz` extracts into a specific directory in one shot, without a separate `cd`. You can extract (or even just list, then extract) a single path out of a huge archive by naming it exactly as it appears inside the archive: `tar -xzf archive.tar.gz path/inside/archive` — this avoids unpacking gigabytes of unrelated data just to pull one file.

### `gzip`/`gunzip` — single-file compression, and the "it deleted my file" gotcha

`gzip` compresses exactly one file (or a stdin stream) at a time — it has no concept of directories, which is precisely why it's normally paired with `tar` first. The gotcha that trips people up constantly: **`gzip file.txt` REPLACES `file.txt` with `file.txt.gz` and deletes the original** — there's no prompt, no "keep original" default. Use `-k` (`--keep`) to retain the source file. `gunzip` (or `gzip -d`) reverses it, with the same replace-by-default behavior in the other direction. Other useful flags: `-c` writes the compressed/decompressed stream to stdout instead of a file (essential for piping), and `-1` through `-9` control the speed/ratio trade-off (`-1` fastest/weakest, `-9` slowest/smallest; `-6` is the default).

A genuinely useful production trick: `zcat`, `zgrep`, and `zless` read the contents of a `.gz` file transparently, without you manually decompressing it to a temp file first. This is the standard way to search rotated/compressed log files (`app.log.3.gz`, etc.) — `zgrep "OutOfMemory" /var/log/app/*.gz` searches every compressed log in one command with no cleanup step.

### `bzip2`/`bunzip2` — better ratio, slower, mostly legacy now

Same single-file model as `gzip` (`bzip2 file`, `-k` to keep the original, `bunzip2` to decompress). It generally compresses better than gzip using a block-sorting algorithm (BWT), at the cost of being noticeably slower. In modern practice it has been largely superseded by `xz`, which beats it on ratio too — you'll still encounter `.tar.bz2` in the wild (older distro source tarballs, some package formats) but it's rarely the *first* choice for new work today.

### `xz`/`unxz` — best ratio, slowest, the modern default for "smallest possible"

`xz` uses the LZMA2 algorithm and consistently produces the smallest output of the three, at the cost of being the most CPU-intensive and slowest to compress (decompression is comparatively cheap). It's the standard choice when final size is what matters most and compression time is not on a hot path — cold-storage backups, distributing large release tarballs (this is why the Linux kernel and most large open-source projects ship `.tar.xz`), archiving build artifacts you rarely touch again.

### Speed/ratio trade-off, at a glance

| Tool | Speed | Ratio | Notes |
|---|---|---|---|
| `gzip` | Fastest | Weakest | Universally available, single-threaded, low CPU cost |
| `bzip2` | Middle | Better than gzip | Slower, largely legacy for new workflows |
| `xz` | Slowest | Best | High CPU cost, standard for "smallest file wins" |

Real-world rule of thumb: reach for **gzip** when speed and near-universal compatibility matter more than the last few percent of size (quick log rotation, CI artifacts, anything decompressed constantly). Reach for **xz** when final size is the priority and you have CPU time to spare (a nightly cold-storage backup, a release tarball users will download once).

### `zip`/`unzip` — self-contained, cross-platform, and randomly accessible

Unlike the `tar` + compressor combo, `zip` does bundling **and** compression in one step and one file format — there's no "archive then compress" two-step, and no need to pick a separate compressor. Its main practical advantage isn't compression ratio (it's typically worse than `tar.gz` on similar data, since it compresses each file individually rather than the whole stream) — it's **interoperability and random access**:
- `.zip` is natively readable/writable on Windows and macOS with no extra tooling, making it the right choice when sending an archive to someone who isn't on Linux/Unix.
- `zip`'s format includes a central directory index at the end of the file, so `unzip` can jump straight to one member file and extract it without reading the whole archive sequentially. A gzip'd tar, by contrast, is a single continuous compressed stream — extracting one file still means decompressing sequentially from the start.

### Which format should you actually use? (Decision rule)

| Format | Speed | Ratio | Cross-platform | Typical use case |
|---|---|---|---|---|
| `.tar.gz` | Fast | Moderate | Needs tar/gzip (default on Linux/Unix/macOS) | General-purpose backups, CI artifacts, source distribution |
| `.tar.bz2` | Slow | Good | Needs tar/bzip2 | Legacy — rarely the first choice today |
| `.tar.xz` | Slowest | Best | Needs tar/xz | Release tarballs, cold storage, when final size matters most |
| `.zip` | Fast–moderate | Moderate (worse than tar.gz usually) | Native everywhere | Sending files to Windows/macOS users; need to extract one file without reading the whole archive |

Bottom line: **`tar.gz` for general-purpose Linux/Unix archiving** (fast, ubiquitous, good enough ratio); **`tar.xz` when final size matters most** and CPU time is cheap; **`zip` when cross-platform interop or random single-file access matters** more than raw compression efficiency.

## Hands-On Examples

**1. Basic create and extract with gzip compression**
```bash
$ tar -czvf app-release.tar.gz app/
app/
app/bin/
app/bin/server
app/config/settings.yml
app/lib/core.so

$ ls -lh app-release.tar.gz
-rw-r--r-- 1 deploy deploy 4.2M Aug  8 09:12 app-release.tar.gz

$ tar -xzvf app-release.tar.gz -C /tmp/restored
app/
app/bin/
app/bin/server
app/config/settings.yml
app/lib/core.so
```

**2. List contents before extracting (never blind-extract an unknown archive)**
```bash
$ tar -tzf unknown_vendor_bundle.tar.gz
vendor/
vendor/bin/install.sh
vendor/etc/vendor.conf
../../etc/passwd          # <-- red flag: path traversal outside archive root

$ # good — now we know to inspect it manually, or extract with --strip-components / into a sandboxed dir
$ tar -xzf unknown_vendor_bundle.tar.gz -C /tmp/sandbox --one-top-level
```

**3. `gzip` replaces the original by default — then redo it with `-k`**
```bash
$ ls -l access.log
-rw-r--r-- 1 www-data www-data 812934 Aug  8 08:00 access.log

$ gzip access.log
$ ls -l access.log*
-rw-r--r-- 1 www-data www-data 94211 Aug  8 08:00 access.log.gz
$ # original access.log is GONE

$ gunzip -k access.log.gz
$ ls -l access.log*
-rw-r--r-- 1 www-data www-data 812934 Aug  8 08:00 access.log
-rw-r--r-- 1 www-data www-data  94211 Aug  8 08:00 access.log.gz
$ # -k on gunzip kept the .gz AND restored the plain file
```

**4. `zcat`/`zgrep` — search compressed logs without decompressing to disk**
```bash
$ ls /var/log/nginx/
access.log      access.log.1.gz  access.log.3.gz
error.log       access.log.2.gz  access.log.4.gz

$ zgrep "504 Gateway Time-out" /var/log/nginx/access.log.*.gz
/var/log/nginx/access.log.2.gz:203.0.113.9 - - [07/Aug/2026:14:02:11] "GET /api/orders HTTP/1.1" 504 176
/var/log/nginx/access.log.3.gz:203.0.113.9 - - [06/Aug/2026:03:47:55] "GET /api/orders HTTP/1.1" 504 176

$ zcat /var/log/nginx/access.log.4.gz | wc -l
48213
```

**5. Comparing xz vs gzip on the same file (ratio and time trade-off)**
```bash
$ ls -lh database_dump.sql
-rw-r--r-- 1 dba dba 512M Aug  8 09:00 database_dump.sql

$ time gzip -k database_dump.sql
real    0m6.812s

$ time xz -k database_dump.sql
real    0m54.203s

$ ls -lh database_dump.sql.gz database_dump.sql.xz
-rw-r--r-- 1 dba dba  98M Aug  8 09:00 database_dump.sql.gz
-rw-r--r-- 1 dba dba  71M Aug  8 09:00 database_dump.sql.xz
$ # xz is ~9x slower here but produces a ~28% smaller file — worth it for a
$ # weekly cold-storage snapshot, not worth it for a dump you compress every 5 minutes
```

**6. `tar --exclude` in a backup context**
```bash
$ tar -czf webapp-backup-$(date +%Y%m%d).tar.gz \
    --exclude='*.log' \
    --exclude='node_modules' \
    --exclude='.git' \
    /srv/webapp

$ tar -tzf webapp-backup-20260808.tar.gz | grep node_modules
$ # (no output — excluded as expected)

$ ls -lh webapp-backup-20260808.tar.gz
-rw-r--r-- 1 root root 61M Aug  8 09:20 webapp-backup-20260808.tar.gz
```

**7. `zip`/`unzip` round trip, and pulling one file back out**
```bash
$ zip -r frontend-dist.zip dist/
  adding: dist/ (stored 0%)
  adding: dist/index.html (deflated 61%)
  adding: dist/assets/app.js (deflated 74%)
  adding: dist/assets/app.css (deflated 68%)

$ unzip -l frontend-dist.zip
Archive:  frontend-dist.zip
  Length      Date    Time    Name
---------  ---------- -----   ----
        0  08-08-2026 09:30   dist/
    18422  08-08-2026 09:30   dist/index.html
   204118  08-08-2026 09:30   dist/assets/app.js
    31207  08-08-2026 09:30   dist/assets/app.css

$ unzip frontend-dist.zip dist/index.html
Archive:  frontend-dist.zip
  inflating: dist/index.html
$ # pulled just one member out — no need to touch app.js or app.css
```

**8. Production-flavored: nightly timestamped backup script**
```bash
$ cat > /usr/local/bin/nightly-backup.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

SRC="/data/postgres-exports"
DEST="/backups"
STAMP=$(date +%Y%m%d-%H%M%S)
ARCHIVE="$DEST/pgexport-$STAMP.tar.xz"

tar -cJf "$ARCHIVE" --exclude='*.tmp' -C / "${SRC#/}"
echo "Backup written: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

# Prune anything older than 14 days
find "$DEST" -name 'pgexport-*.tar.xz' -mtime +14 -delete
EOF
$ chmod +x /usr/local/bin/nightly-backup.sh

$ /usr/local/bin/nightly-backup.sh
Backup written: /backups/pgexport-20260808-020000.tar.xz (2.1G)
```

## Practice Questions

1. You run `gzip database.sql` and it appears to "vanish" — the original file is nowhere to be found. What actually happened, and what flag would you have needed to prevent it?
2. Someone hands you a `.tar.gz` from an unknown source. Walk through the safe way to inspect it before extracting, and explain what you'd look for that would make you NOT extract it directly.
3. You need to pull one 2KB config file out of a 40GB `application.tar.gz` backup without extracting the whole thing. What command do you run, and what determines whether it works on the first try?
4. A teammate says "just gzip the folder before you send it." Explain why this doesn't work as stated, and what command they actually need.
5. You need to search for `"connection refused"` across 30 rotated, gzip-compressed log files (`app.log.1.gz` through `app.log.30.gz`) without filling up disk with temporary decompressed copies. What command(s) do you use?
6. Your team is deciding between `.tar.gz` and `.tar.xz` for nightly backups of a 200GB dataset that runs on a shared CPU-constrained host. Which do you pick and why? What would change your answer?
7. A non-technical stakeholder on Windows needs a folder of reports emailed to them. Would you send a `.tar.gz` or a `.zip`, and why — beyond "zip is more common," what's the actual technical reason?
8. Write a `tar` command that archives `/etc` into a compressed archive while excluding `/etc/ssl/private` and `*.bak` files, and explain why `--exclude` order/placement relative to the source path can matter.
9. Explain, mechanically, why `tar.gz` sometimes compresses better than `.zip` on the same set of text files, even though both ultimately use DEFLATE-family algorithms.
10. Design a log-rotation-and-archive policy for a service producing ~5GB of logs/day: what do you compress with day-to-day (speed matters, logs are grepped often), and what do you eventually re-compress with for long-term cold storage (size matters, rarely read)? Justify both choices.

## Interview Key Points

- `tar` only bundles — compression is always a separate, bolted-on step via `-z`/`-j`/`-J` (or piping); this "tar doesn't compress" distinction is one of the most commonly probed basics.
- `gzip`/`bunzip2`-family tools operate on a **single file** and **replace the original by default** — `-k` to keep it. This exact gotcha is a favorite "what actually happens here" interview trap.
- `tar -tzf` (list, don't extract) before `tar -xzf` on any unfamiliar archive is the expected safe-handling answer, especially for archives from external/untrusted sources (path traversal risk).
- `zcat`/`zgrep`/`zless` read compressed files in place — know this as the standard way to search rotated logs (`*.log.N.gz`) without a manual decompress-then-cleanup step.
- Speed/ratio ordering is a memorization point interviewers check quickly: gzip fastest/weakest, bzip2 middle (largely legacy now), xz slowest/best — and *why* (algorithm: DEFLATE vs BWT vs LZMA2) if pushed deeper.
- Know when to justify `zip` over `tar.gz`: cross-platform interop (native on Windows/macOS) and random single-file access via zip's central directory — not because it compresses better, because it usually doesn't.
- Practical flag fluency matters: `-f` last before the filename, `--exclude` for skipping paths during archiving, `-C` to extract into a target directory without `cd`, and extracting a single path by naming it exactly as stored in the archive.
- Interviewers are ultimately probing for judgment, not memorized flags: can you justify gzip vs xz vs zip for a *specific* scenario (CPU budget, read frequency, audience OS) rather than reciting "xz is better."
