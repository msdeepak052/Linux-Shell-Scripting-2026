# Wildcards & Globbing (`*`, `?`, `[]`, `{}`)

Globbing is how the shell itself expands filename patterns into matching filenames *before* running a command — every `rm`, `cp`, `ls`, or `mv` on multiple files leans on it, and misunderstanding it is one of the most common causes of accidental mass-deletion incidents.

## Explanation

**Globbing happens in the shell, not in the command.** When you type `rm *.log`, bash expands `*.log` into a literal list of matching filenames (e.g., `rm app.log error.log`) *before* `rm` ever runs. `rm` never sees a wildcard — it just sees a list of arguments. This is why `echo *.log` is a safe way to preview what a glob matches before running something destructive with it.

**The core glob metacharacters:**
- `*` — matches zero or more of ANY characters (except a leading `.` unless `dotglob` is set). `*.txt` matches `a.txt`, `report.txt`, but not `.hidden.txt`.
- `?` — matches exactly ONE character. `file?.txt` matches `file1.txt`, `fileA.txt`, but not `file10.txt`.
- `[...]` — matches exactly ONE character from the set/range inside. `[abc]`, `[a-z]`, `[0-9]`, `[a-zA-Z0-9]` are all valid.
- `[!...]` or `[^...]` — matches exactly ONE character NOT in the set. `[!0-9]` matches any single non-digit char.
- `{...}` — **brace expansion** — NOT technically globbing at all (see below), but always discussed alongside it.

**Brace expansion `{a,b,c}` and ranges `{1..10}`:** This is a separate, earlier shell feature (pure text expansion, no filesystem lookup involved). `{a,b,c}` expands to the literal words `a b c`. `mkdir dir{1,2,3}` creates `dir1 dir2 dir3` even if none of them exist yet — brace expansion doesn't care whether anything matches on disk. Ranges work too: `{1..10}`, `{01..10}` (zero-padded), `{a..e}`, and even with a step: `{1..10..2}`. Brace expansion can also produce non-existent-looking combos deliberately, e.g. `cp file.txt{,.bak}` expands to `cp file.txt file.txt.bak`.

**Globbing vs regex — the most common confusion in interviews:** They look similar but are fundamentally different engines with different semantics:
| | Globbing | Regex |
|---|---|---|
| `*` means | zero-or-more of ANY char | zero-or-more of the **preceding** char |
| `.` means | literal dot | any single character |
| Used by | shell (filename expansion), `find -name` | `grep`, `sed`, `awk`, `find -regex` |
| `?` means | exactly one char | zero-or-one of preceding char |

So `*.txt` in the shell means "anything ending in .txt", but the equivalent regex is `.*\.txt` — a very common "gotcha" question. Also: `find -name "*.txt"` uses **globbing**, while `grep -E ".*\.txt"` uses **regex** — same-looking patterns, different rules.

**Order of shell expansion matters:** brace expansion happens FIRST, then globbing (pathname expansion) is applied to whatever brace expansion produced. So `ls file{1,2}*.txt` first becomes `ls file1*.txt file2*.txt`, and only then does the shell glob-match each piece against the filesystem.

**Key `shopt` options that change globbing behavior:**
- `nullglob` — if a glob matches nothing, it normally expands to itself (the literal pattern string, e.g. `*.xyz` stays as `*.xyz` if nothing matches). With `shopt -s nullglob`, a non-matching glob expands to **nothing** (empty) instead — critical for safe loops like `for f in *.log; do ...; done` so you don't process a literal `*.log` string when the directory is empty.
- `dotglob` — by default, `*` does NOT match hidden files (dotfiles like `.bashrc`). `shopt -s dotglob` makes `*` match dotfiles too. Without it, `rm -rf *` in a directory leaves dotfiles behind (sometimes a "gotcha" for people expecting a truly empty dir).
- `extglob` — enables extended pattern operators: `?(pattern)`, `*(pattern)`, `+(pattern)`, `@(pattern)`, `!(pattern)` (e.g. `!(*.log)` = everything EXCEPT files ending in .log) — closer to regex power within globbing syntax.

## Hands-On Examples

**1. Basic `*` and `?` matching**
```bash
$ ls
app.log  error.log  file1.txt  file2.txt  file10.txt  notes.md

$ ls *.log
app.log  error.log

$ ls file?.txt
file1.txt  file2.txt          # file10.txt excluded — ? matches exactly one char

$ ls file*.txt
file1.txt  file2.txt  file10.txt
```

**2. Character classes with `[...]` and `[!...]`**
```bash
$ ls
log1.txt  log2.txt  log3.txt  logA.txt  logB.txt

$ ls log[1-3].txt
log1.txt  log2.txt  log3.txt

$ ls log[!1-3].txt
logA.txt  logB.txt

$ ls log[12A].txt
log1.txt  log2.txt  logA.txt
```

**3. Brace expansion for bulk directory/file creation**
```bash
$ mkdir -p project/{src,bin,docs,tests}
$ ls project/
bin  docs  src  tests

$ touch app_{dev,staging,prod}.conf
$ ls
app_dev.conf  app_staging.conf  app_prod.conf

# Nested + ranges
$ mkdir -p backup/{2024,2025}/{01..12}
$ ls backup/2025/
01  02  03  04  05  06  07  08  09  10  11  12
```

**4. Quick backup pattern using brace expansion**
```bash
$ cp nginx.conf{,.bak}
$ ls nginx.conf*
nginx.conf  nginx.conf.bak
```

**5. Safely previewing a destructive glob before running it**
```bash
$ echo rm /var/log/app/*.log.[0-9]
rm /var/log/app/access.log.1 /var/log/app/access.log.2 /var/log/app/error.log.1

# Looks right — now actually run it
$ rm /var/log/app/*.log.[0-9]
```

**6. Matching a date range of log files**
```bash
$ ls /var/log/backups/
backup_2026-08-01.tar.gz  backup_2026-08-02.tar.gz  backup_2026-08-03.tar.gz
backup_2026-07-31.tar.gz  backup_2026-08-15.tar.gz

$ ls backup_2026-08-0[1-3].tar.gz
backup_2026-08-01.tar.gz  backup_2026-08-02.tar.gz  backup_2026-08-03.tar.gz
```

**7. `nullglob` preventing a broken loop on empty matches**
```bash
$ ls /tmp/emptydir/
$ for f in /tmp/emptydir/*.tmp; do echo "Found: $f"; done
Found: /tmp/emptydir/*.tmp        # BUG: glob didn't match, so it stays literal

$ shopt -s nullglob
$ for f in /tmp/emptydir/*.tmp; do echo "Found: $f"; done
$                                  # correctly prints nothing
```

**8. `dotglob` and hidden files — a common `rm -rf *` gotcha**
```bash
$ ls -a cleandir/
.  ..  .env  .gitignore  data.csv

$ rm -rf cleandir/*
$ ls -a cleandir/
.  ..  .env  .gitignore           # dotfiles survived — * doesn't match hidden files by default

$ shopt -s dotglob
$ rm -rf cleandir/*
$ ls -a cleandir/
.  ..                             # now truly empty
```

## Practice Questions

1. What's the difference between `file?.txt` and `file*.txt`? Give example filenames each would and would not match.
2. Explain why `rm -rf *` in a directory full of dotfiles (`.env`, `.git`) does NOT delete them, and how you'd make it do so (name the `shopt` option).
3. You run `for f in *.bak; do rm "$f"; done` in a directory with no `.bak` files, and it errors trying to `rm` a file literally named `*.bak`. What's happening, and what one-line fix prevents it?
4. What's the difference between `mkdir dir{1,2,3}` and `mkdir dir[1-3]`? (Trick: one is brace expansion, one is a glob — explain why only one of them works reliably here.)
5. A colleague writes `find . -name "*.txt"` and then complains that `grep -E "*.txt" file` behaves completely differently and errors out. Explain why — what's fundamentally different between glob `*` and regex `*`?
6. Write a single command using brace expansion to create backup copies of `config.yaml`, `secrets.yaml`, and `app.yaml`, each with a `.bak` suffix, without repeating `cp` three times.
7. Given files `srv01.log` through `srv20.log`, write a glob pattern that matches only `srv01.log` through `srv09.log` (single digit, zero-padded).
8. You're asked to delete every file in a directory EXCEPT `.conf` files. Show how `extglob`'s `!(pattern)` solves this, and explain why you'd need `shopt -s extglob` first.
9. Why is `echo somepattern*` a good habit to run before `rm somepattern*` in production? What real incident does this habit prevent?
10. Explain the shell's expansion order when it sees `cp file{1,2}.{txt,log} /backup/` — walk through brace expansion and globbing step by step, and list the exact set of resulting filenames the shell tries to copy.

## Interview Key Points

- **Globbing is NOT regex** — despite looking similar, `*` in a glob means "any characters" (equivalent to regex `.*`), while `*` in regex means "zero or more of the preceding character." This confusion is one of the most frequently tested points — know that `find -name` globs, but `grep`/`sed`/`find -regex` use regex.
- **Globbing happens in the shell before the command runs** — commands like `rm`, `cp`, `ls` never see the wildcard itself, only the expanded file list. This is why `echo pattern*` is the standard safe way to preview a glob before a destructive operation.
- **Brace expansion `{}` is not globbing** — it's pure text expansion with no filesystem awareness, and it happens BEFORE pathname expansion in the shell's parsing order. `mkdir dir{1,2,3}` works even though none of those directories exist yet; a glob like `dir[1-3]` would NOT work for creation because globs only match things that already exist.
- **Hidden-file gotcha (`dotglob`)**: `*` does not match dotfiles by default — a very common surprise when someone expects `rm -rf *` to fully empty a directory. Know `shopt -s dotglob` to opt in.
- **`nullglob` matters for safe scripting** — without it, a glob with zero matches expands to its own literal pattern string, silently breaking loops (`for f in *.log`) when the directory has no matches; `shopt -s nullglob` makes it expand to nothing instead.
- **Danger of overly broad globs in `rm`**: patterns like `rm -rf *foo*` or `rm *` run in the wrong directory (or with an unintended `cd` beforehand) are a classic cause of production incidents — always sanity-check with `pwd` and `echo` first, and prefer `-i` (interactive) for anything destructive and irreversible.
- **`extglob`** unlocks regex-like power inside glob syntax (`!(pattern)`, `@(pattern)`, `+(pattern)`) — worth knowing exists even if less commonly used day-to-day, especially for "delete everything except X" scenarios.
