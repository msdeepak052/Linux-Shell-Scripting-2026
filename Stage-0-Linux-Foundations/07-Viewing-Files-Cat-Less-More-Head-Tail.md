# Viewing Files: `cat`, `less`, `more`, `head`, `tail`, `tail -f`

Reading files quickly and correctly — without accidentally dumping a 4GB log into your terminal — is a daily reflex for any platform engineer, and `tail -f` is the single most-used command during a live incident.

## Explanation

These tools all display file content, but they're built for very different jobs:

| Tool | Best for | Loads whole file? | Interactive? | Follows growth? |
|---|---|---|---|---|
| `cat` | Small files, concatenation, piping into other commands | Yes (prints all at once) | No | No |
| `more` | Legacy pager, forward-only paging | No (streams) | Minimal | No |
| `less` | Paging large files, searching, scrolling both ways | No (streams, loads on demand) | Yes, rich | Yes (`less +F` / `F` key) |
| `head` | Peek at the start of a file (headers, first N lines) | No (reads only what's needed) | No | No |
| `tail` | Peek at the end of a file (recent log lines) | No (reads only what's needed) | No | No |
| `tail -f` | Watch a file grow in real time (live logs) | No | No (blocks/streams) | Yes |

**`cat`** ("concatenate") just dumps the file to stdout. Fine for small files or piping (`cat file | grep x`), but running `cat` on a multi-GB log floods your terminal and is a classic junior mistake — the interviewer wants to hear "I'd use `less` instead."

**`more`** is the original pager: forward-only, page-by-page (`Space` = next page, `Enter` = next line, `q` = quit). It's largely obsolete but still shows up on minimal/embedded systems where `less` isn't installed.

**`less`** ("less is more") is the modern standard pager — it does NOT load the entire file into memory, so it opens huge files instantly. Key bindings:

| Key | Action |
|---|---|
| `Space` / `b` | Page down / page up |
| `/pattern` | Search forward |
| `?pattern` | Search backward |
| `n` / `N` | Next / previous match |
| `g` / `G` | Go to start / end of file |
| `F` | Follow mode (like `tail -f`, live-updating) |
| `Ctrl+C` then `q` | Exit follow mode / quit |
| `&pattern` | Show only lines matching pattern (filter view) |

**`head`** and **`tail`** print the first/last N lines (default 10). `-n` sets the count, `-c` counts bytes instead of lines. `-f` on `tail` is the killer feature: it keeps the file open and prints new lines as they're appended — this is how you watch a log during a deploy or incident. `tail -F` (capital) is safer for log files that get rotated (deleted/recreated) — it re-opens the file by name if the inode changes, whereas `-f` keeps following the old (now-detached) inode and goes silent.

**Gotchas**:
- `cat` on a binary file can corrupt your terminal (garbage characters, altered prompt) — use `less` (it detects binary and warns) or `xxd`/`hexdump` instead.
- `tail -f` alone will silently stop producing output after `logrotate` rotates the file — always use `tail -F` (or `--follow=name --retry`) for production log watching.
- `less -F` ("quit if one screen") makes `less` exit immediately and print like `cat` when the content fits on one screen, but still page normally for longer output — a nice default for scripts that pipe into `less`. Don't confuse this with `tail -F` (follow-by-name after rotation); same flag letter, unrelated meaning.
- `head -n -5 file` prints all but the last 5 lines (negative count) — same trick works with `tail -n +5` to print from line 5 onward.
- Multiple files: `tail -f file1 file2` interleaves both, prefixing output with `==> filename <==` headers whenever it switches source.

## Hands-On Examples

**1. `cat` — small files and concatenation**
```bash
$ cat /etc/hostname
prod-web-03

$ cat file1.conf file2.conf > combined.conf
$ cat -n /etc/fstab | head -3
     1	UUID=8f3a2b1c-... /               ext4    defaults        0 1
     2	UUID=9d4e5c2a-... /boot           ext4    defaults        0 2
     3	/dev/mapper/vg0-swap none         swap    sw              0 0
```

**2. `head` / `tail` — quick peeks**
```bash
$ head -5 /var/log/syslog
Aug  8 09:00:01 prod-web-03 CRON[1122]: (root) CMD (run-parts /etc/cron.hourly)
Aug  8 09:00:02 prod-web-03 systemd[1]: Starting Daily apt cache cleanup...
...

$ tail -20 /var/log/nginx/error.log
2026/08/08 10:14:02 [error] 8931#8931: *4521 connect() failed (111: Connection refused) while connecting to upstream
...

$ tail -c 100 /var/log/app.log      # last 100 bytes, useful for huge single-line files
```

**3. `less` — paging and searching a huge file**
```bash
$ less /var/log/syslog
# inside less:
/OutOfMemory<Enter>       # search forward for OOM events
n                          # jump to next match
G                          # jump to end of file
q                          # quit
```

**4. `less` on piped command output (very common)**
```bash
$ journalctl -u nginx --since "1 hour ago" | less
$ dmesg | less
$ ps aux --sort=-%mem | less
```

**5. `tail -f` — watching a live deploy**
```bash
$ tail -f /var/log/app/deploy.log
2026-08-08 11:02:10 INFO  Pulling image myapp:v2.14.0
2026-08-08 11:02:14 INFO  Image pulled successfully
2026-08-08 11:02:15 INFO  Rolling restart: pod myapp-7d4f9c-2xk9q
2026-08-08 11:02:22 INFO  Pod myapp-7d4f9c-2xk9q ready
^C
```

**6. `tail -F` vs `tail -f` across log rotation (production-critical)**
```bash
$ tail -f /var/log/app.log &
[1] 20411
# ...logrotate runs, renames app.log -> app.log.1, creates new empty app.log...
# tail -f keeps following the OLD (rotated-away) file: no new output ever appears again

$ kill %1
$ tail -F /var/log/app.log &
# logrotate runs again
# tail -F detects the new file by name and re-attaches automatically, output continues
```

**7. Incident response: filtering a live-tailed log for errors**
```bash
$ tail -f /var/log/app/app.log | grep --line-buffered -i "error\|exception\|timeout"
2026-08-08 11:15:03 ERROR DB connection timeout after 5000ms
2026-08-08 11:15:03 ERROR Retrying connection (attempt 2/5)
2026-08-08 11:15:09 EXCEPTION java.net.SocketTimeoutException: connect timed out
```
`--line-buffered` is required on `grep` here — without it, `grep`'s output buffering delays matches until enough data accumulates, defeating the point of real-time tailing.

**8. Combining `head`/`tail` with `-n +N` for a middle slice**
```bash
$ tail -n +100 access.log | head -n 50    # lines 100-149 of a huge file, without loading it all
```

## Practice Questions

1. You need to inspect a 12 GB log file on a production server with limited free memory. Would you use `cat` or `less`? Explain why `cat` is a bad idea here.
2. What's the practical difference between `more` and `less`? Why has `less` largely replaced `more`?
3. During an incident, you run `tail -f /var/log/app.log` and after a few minutes the output just stops, even though the application is clearly still logging. What's most likely happening, and what command would you use instead?
4. How do you print only lines 200-250 of a file without opening the whole thing in an editor?
5. You `tail -f` a log and pipe it into `grep`, but matching lines don't appear until much later than when they were written. What's causing the delay, and how do you fix it?
6. What does `head -n -10 file.txt` do? Give a practical use case.
7. Inside `less`, how do you search for "OutOfMemoryError", jump to the next match, and then jump straight to the end of the file?
8. What happens if you accidentally run `cat` on a binary file (e.g., a compiled executable)? How do you recover your terminal afterward, and what command should you have used instead?
9. You want to watch two log files simultaneously (app.log and error.log) for new entries as they arrive. What single command achieves this, and how does the output distinguish which file a line came from?
10. Explain the difference between `tail -f` and `tail -F`, and specifically why `-F` is the safer default for monitoring application logs in production.

## Real Interview Questions (Company-Attributed)

- "How do you display the last 10 lines of a large log file without opening it fully?" — asked at *HCL*
- "How do you print the last 15 lines of a file in Linux?" — asked at *an unnamed company (via community-sourced interview notes)*

## Interview Key Points

- **`cat` vs `less` on large files** is a very common "gotcha" question — `cat` reads/prints everything into your terminal buffer at once (slow, can hang a terminal, useless for searching); `less` streams and loads on demand, so it opens instantly regardless of file size.
- **`tail -f` vs `tail -F`** is a favorite senior-level trap: `-f` follows by file descriptor/inode and goes silent after log rotation; `-F` (`--follow=name --retry`) re-opens by filename, which is what you actually want for production log monitoring.
- Know `less` is not just "a pager" — it supports searching (`/`, `?`, `n`, `N`), jumping (`g`/`G`), and even live-follow mode (`F` key, equivalent to `tail -f` from inside `less`).
- `head -n -N` and `tail -n +N` (negative/plus offsets) are underused but come up in scripting questions — "print everything except the last 5 lines" or "print from line 10 onward."
- `grep --line-buffered` (or `stdbuf -oL`) is the fix when piping `tail -f` into another command that buffers — a good example of understanding stdout buffering, not just tool syntax.
- Multiple-file `tail`/`head` output the `==> filename <==` header automatically when given more than one file — useful to mention when asked about monitoring several logs at once.
- `cat` on a binary file scrambling your terminal (control characters changing colors/encoding) is a real "war story" question — recovery is typically `reset` or `stty sane`.
