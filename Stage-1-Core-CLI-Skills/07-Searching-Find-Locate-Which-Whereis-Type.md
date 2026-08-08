# Searching: `find`, `locate`, `which`, `whereis`, `type`

Five commands that all answer "where is X," but each queries a different source of truth (live filesystem, cached database, `$PATH`, fixed system paths, or the shell itself) — picking the wrong one gives you a stale, incomplete, or outright misleading answer, which is exactly why this is a recurring interview trap.

## Explanation

### `find` — real-time filesystem traversal
`find` walks the actual directory tree at the moment you run it. That makes it always accurate (it can never be stale) but also the slowest of the group on huge filesystems, since every directory has to be `stat()`-ed live. It's also the only tool here that's a full query+action engine rather than a simple lookup.

Common predicates:
- `-name "pattern"` — glob match, **case-sensitive**. `-iname "pattern"` — same but case-insensitive.
- `-type f|d|l` — regular file, directory, or symlink.
- `-mtime N` / `-mmin N` — modified N days/minutes ago. The sign is the classic gotcha:
  - `-mtime -1` → modified **less than** 1 day ago (recent files)
  - `-mtime +7` → modified **more than** 7 days ago (old files)
  - `-mtime 3` (no sign) → modified **exactly** in the 3-to-4-day-ago window
  - Mnemonic: `-N` means "newer than N," `+N` means "older than N" — the sign points away from "now."
- `-size +100M` — larger than 100 MB (`-100M` = smaller than).
- `-perm -4000` — SUID bit set (the leading `-` means "at least these bits," useful for security audits).
- `-user`/`-group` — owned by a given user/group.

Action flags:
- `-delete` — deletes matches directly inside `find` itself. Fast, but dangerous: it deletes whatever the preceding predicates matched, so a mistyped `-name` or missing `-type f` can wipe directories you didn't intend. Always dry-run without `-delete` first.
- `-exec cmd {} \;` — runs `cmd` **once per matched file**. Simple but slow when thousands of files match, since it forks a new process every time.
- `-exec cmd {} +` — batches as many `{}` as fit on one command line into a **single (or few) invocation(s)**, exactly like `xargs` does internally. Dramatically faster for large result sets. This is the detail interviewers probe for: candidates who only know `\;` haven't hit real scale.
- Piping to `xargs`: `find . -name "*.log" -print0 | xargs -0 rm -f`. The `-print0` / `xargs -0` pairing delimits filenames with a NUL byte instead of a newline/space. Without it, any filename containing a space, tab, or newline gets split into multiple "arguments" by `xargs`, silently corrupting the command — a well-known real-world trap (e.g., a file literally named `report final.log` becomes two args, `report` and `final.log`).

### `locate` — prebuilt database lookup
`locate` (via `mlocate` or the modern `plocate`) never touches the filesystem at query time — it searches a pre-indexed database (typically `/var/lib/mlocate/mlocate.db` or `/var/lib/plocate/plocate.db`). That makes it near-instant even across an entire filesystem, but with three consequences:
1. **Staleness**: the database is normally rebuilt once a day by a cron job running `updatedb`. A file created (or deleted) 5 minutes ago won't show up (or will show up as a false positive) until the next `updatedb` run.
2. **Permission-blind at index time, but respects it at query time for `plocate`/modern `mlocate`**: it won't return paths the querying user can't actually access, based on permissions captured when the database was built.
3. **Respects `/etc/updatedb.conf` excludes**: paths/filesystems listed in `PRUNEPATHS` or `PRUNEFS` (e.g., `/tmp`, network mounts) are never indexed, so `locate` will never find files there no matter how fresh the database is.

### `which` — resolves what `$PATH` would execute
`which command_name` scans the directories listed in `$PATH`, in order, and prints the first matching executable it finds. It answers "if I typed this and the shell fell through to `$PATH` lookup, what binary would run." Critically, `which` has **no visibility into shell aliases, functions, or builtins** — it only knows about files on disk in `$PATH`. If `ll` is a shell alias with no corresponding binary, `which ll` reports nothing found (or, on some systems, misleadingly greps your shell rc files and prints the alias definition, which is not the same as confirming it will run).

### `whereis` — binary + man page + source, from fixed system paths
`whereis command_name` searches a hardcoded set of standard system locations (`/bin`, `/usr/bin`, `/usr/share/man`, etc. — **not** `$PATH`) and reports the binary, its man page, and (if installed) its source. It's broader than `which` in what categories it reports, but it doesn't respect a customized `$PATH`, so a binary living in a nonstandard directory won't show up even though your shell would find and run it fine. In day-to-day platform work it's used less often than the other four.

### `type` — the shell's own answer (the most authoritative)
`type name` is a **shell builtin**, not a separate executable — it asks the shell directly how it would interpret `name` if you typed it right now. That's precisely why it's the most reliable answer to "what actually runs when I type this command": it checks, in the shell's real resolution order, whether `name` is an alias, a shell function, a shell builtin (like `cd` or `echo`), a keyword (like `if`), or an external file (in which case it also reports the `$PATH` location, effectively including everything `which` does). `type -a name` lists **every** match across all categories, in the order the shell would try them — invaluable when an alias or function is silently shadowing a real binary of the same name.

### `find` vs `locate`, and `which` vs `type` vs `whereis` (Decision rule)
- **"I need to search by attribute (name pattern, size, age, permissions, owner) and possibly act on the results (delete, chmod, batch-process)"** → `find`. It's the only one of the two with predicates and actions; slower, but always correct and far more powerful.
- **"I just need to know where some file/binary is, fast, and a slightly stale answer is fine"** → `locate`. Great for "I know this exists somewhere on disk, just tell me the path" without walking `/`.
- **"What will actually run when I type this command right now?"** → `type` first, always. It's the only one of the three that accounts for aliases, functions, and builtins — the other two will lie by omission for those cases.
- **"I specifically need the binary's `$PATH` location and nothing else"** → `which` is fine, as long as you already know it isn't an alias/function (check with `type` first).
- **"I want the man page and/or source location too, not just the binary"** → `whereis`.

## Hands-On Examples

**1. Basic name search with `find`**
```bash
$ find /etc -name "*.conf"
/etc/ssh/ssh_config
/etc/ssh/sshd_config
/etc/logrotate.conf
/etc/sysctl.conf

$ find /etc -iname "*NGINX*"
/etc/nginx
/etc/nginx/nginx.conf
```

**2. `-mtime` for a log-cleanup script (the sign gotcha in action)**
```bash
$ find /var/log/myapp -type f -name "*.log" -mtime -1
/var/log/myapp/app-2026-08-08.log        # modified within the last day

$ find /var/log/myapp -type f -name "*.log" -mtime +30
/var/log/myapp/app-2026-06-15.log        # older than 30 days
/var/log/myapp/app-2026-06-20.log
/var/log/myapp/app-2026-07-01.log
```

**3. SUID audit with `-perm`**
```bash
$ find / -xdev -perm -4000 -type f 2>/dev/null
/usr/bin/sudo
/usr/bin/passwd
/usr/bin/su
/usr/bin/mount
/usr/bin/chsh
/opt/legacy-app/bin/setuid_helper          # <- unexpected, flag this for review
```
`-xdev` keeps `find` from crossing into other mounted filesystems (e.g., NFS shares), which both speeds the scan up and keeps results scoped to the local root filesystem being audited.

**4. `-exec \;` vs `-exec +` vs `xargs` — the performance difference**
```bash
# Slow: forks md5sum once PER file (3000+ separate process starts)
$ time find /data/uploads -type f -name "*.tmp" -exec md5sum {} \; > /tmp/sums.txt
real    0m42.187s

# Fast: batches files into a handful of md5sum invocations
$ time find /data/uploads -type f -name "*.tmp" -exec md5sum {} + > /tmp/sums.txt
real    0m3.402s

# Equivalent speed via xargs, with NUL-safety for filenames with spaces
$ find /data/uploads -type f -name "*.tmp" -print0 | xargs -0 md5sum > /tmp/sums.txt
real    0m3.115s
```

**5. Why `-print0`/`-0` matters — filenames with spaces**
```bash
$ ls /data/reports/
'monthly report final.csv'   Q3-summary.csv

# WITHOUT null-delimiting: xargs sees THREE arguments, breaks
$ find /data/reports -name "*.csv" | xargs rm -f
rm: cannot remove 'monthly': No such file or directory
rm: cannot remove 'report': No such file or directory
rm: cannot remove 'final.csv': No such file or directory

# WITH null-delimiting: filenames are treated as one atomic unit each
$ find /data/reports -name "*.csv" -print0 | xargs -0 rm -f
$ ls /data/reports/
$
```

**6. `locate` staleness demo**
```bash
$ touch /srv/www/newfile.html
$ locate newfile.html
                                          # nothing — updatedb hasn't run since the file was created

$ find / -name "newfile.html" 2>/dev/null
/srv/www/newfile.html                    # find sees it immediately, live

$ sudo updatedb
$ locate newfile.html
/srv/www/newfile.html                    # now indexed and found
```

**7. `which` / `type` / `whereis` on the same name — where an alias hides the truth**
```bash
$ alias ll='ls -alF --color=auto'

$ which ll
                                          # nothing found — which doesn't know about aliases

$ type ll
ll is aliased to `ls -alF --color=auto'

$ type -a ls
ls is /usr/bin/ls

$ which ls
/usr/bin/ls

$ whereis ls
ls: /usr/bin/ls /usr/share/man/man1/ls.1.gz

# a trickier case: someone defined a function/alias shadowing a real tool
$ type python
python is /usr/bin/python3
$ type -a python
python is /usr/bin/python3
python is /usr/local/bin/python           # a second match further down $PATH — shadowed, worth flagging
```

**8. Production one-liner: cron job to purge old logs safely**
```bash
$ crontab -l
0 3 * * * find /var/log/myapp -type f -name "*.log" -mtime +30 -exec rm -f {} + >> /var/log/myapp/cleanup.log 2>&1

# safe dry-run first, before wiring it into cron
$ find /var/log/myapp -type f -name "*.log" -mtime +30
/var/log/myapp/app-2026-06-10.log
/var/log/myapp/app-2026-06-18.log
/var/log/myapp/app-2026-06-25.log
```

## Practice Questions

1. You run `find /backups -mtime -7` and get zero results even though you know files were modified this week. What's the most likely mistake, and what does `-mtime -7` actually mean versus `+7`?
2. Write a `find` command that deletes all `*.tmp` files under `/tmp/build` older than 3 days, and explain why you'd test it without `-delete` first.
3. A teammate's cleanup script uses `find /data -name "*.bak" -exec rm {} \;` and complains it's "too slow" on a directory with 50,000 matching files. What's the fix, and why is it faster?
4. Explain what can go wrong with `find /uploads -name "*.jpg" | xargs rm` if some filenames contain spaces, and show the corrected command.
5. `locate` returns a path for a file that was deleted an hour ago. Why does this happen, and what command fixes it immediately (versus waiting)?
6. A file exists under `/mnt/nfs-share/data.csv` but `locate data.csv` never finds it even right after `updatedb`. What configuration would explain this?
7. You need to find every file with the SUID bit set on a server as part of a security audit. Write the `find` command, and explain why you'd add `-xdev`.
8. A user says `which mycmd` returns nothing, but typing `mycmd` in their shell runs something. What's going on, and which command would you run to get the real answer?
9. `type -a python` shows two different `python` binaries in different directories. What does this tell you about `$PATH` ordering, and why might this matter for a deploy that "works on my machine but not in CI"?
10. Design a nightly cron job that removes application log files older than 30 days from `/var/log/myapp`, is safe against filenames containing spaces, and logs what it deleted. Walk through your command choice and why.

## Real Interview Questions (Company-Attributed)

- "Write a Unix command to find all files with size greater than 1 GB." — asked at *Akamai*
- "Write a script to find all files in the current directory and subdirectories modified more than 5 hours ago but not beyond today." — asked at *Sigmoid*

## Interview Key Points

- **`find` is always accurate but slower; `locate` is fast but can be stale** — the staleness trap (files created/deleted since the last `updatedb` run) is the single most common "gotcha" question on this topic.
- **`-mtime -N` vs `-mtime +N` sign direction** is a classic trick question — `-N` means "within the last N days" (newer), `+N` means "more than N days ago" (older); getting this backwards in a cleanup script deletes the wrong files.
- **`-exec {} \;` forks once per file; `-exec {} +` (or `xargs`) batches invocations** — know this cold, it's the standard "how do you make find fast at scale" follow-up.
- **`-print0` / `xargs -0`** exists specifically to null-delimit filenames so spaces/newlines in names don't get mis-split into multiple arguments — always mention this when discussing `find | xargs` pipelines, since omitting it is a real production bug pattern, not just theory.
- **`which` cannot see aliases, functions, or builtins** — it only resolves `$PATH` binaries, so it can give a "nothing found" or misleading answer for names that are actually aliased or are shell builtins.
- **`type` is the most authoritative "what will run" answer** because it mirrors the shell's own resolution order (alias → function → builtin → keyword → `$PATH` file); `type -a` is the tool for diagnosing "why is the wrong version of this command running."
- **`whereis` uses a fixed set of system paths, not `$PATH`**, and adds man-page/source-file locations on top of the binary — broader category coverage than `which`, but blind to nonstandard install locations your shell would actually use.
- **`-delete` and `-exec rm` inside `find` are destructive by construction** — interviewers expect you to mention dry-running the search predicates first (without the action) before wiring any `find ... -delete` or `find ... -exec rm` into automation or cron.
