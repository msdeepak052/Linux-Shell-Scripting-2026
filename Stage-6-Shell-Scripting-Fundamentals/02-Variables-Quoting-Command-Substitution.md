# Variables, Quoting & Command Substitution

The single biggest source of "works on my machine" bash bugs is quoting. Get this right early.

## Explanation

**Variables**: no `$` on assignment, `$` (or `${}`) on use, **no spaces around `=`**.
```bash
name="deepak"       # correct
name = "deepak"     # WRONG — bash parses this as running a command "name" with args "=" "deepak"
```
Variables are untyped strings by default (even numbers), unless declared with `declare -i` for integers, `declare -a`/`declare -A` for arrays.

**Quoting — three kinds, three behaviors**:
| Quote | Variable expansion? | Command substitution? | Literal `*`, `$`, backslash? |
|---|---|---|---|
| `'single'` | No | No | Fully literal |
| `"double"` | Yes | Yes | Mostly literal except `$`, `` ` ``, `\`, `"` |
| `` `backtick` `` / `$()` | N/A (used for substitution, not quoting) | — | — |

**Golden rule**: always double-quote variable expansions (`"$var"`), unless you specifically want word-splitting/globbing to happen. Unquoted `$var` is expanded, then **word-split** on `$IFS` and **glob-expanded** — this is the #1 cause of bugs with filenames containing spaces.

**Command substitution**: `$(command)` runs `command` in a subshell and substitutes its stdout (trailing newlines stripped). Backticks `` `command` `` do the same but are legacy — nesting them requires escaping (`` `echo \`date\`` ``), while `$(...)` nests cleanly (`$(echo $(date))`). Always prefer `$()`.

## Hands-On Examples

**1. Assignment syntax and the space trap**
```bash
$ name="platform-eng"
$ echo $name
platform-eng

$ name = "platform-eng"
bash: name: command not found
```

**2. Single vs double quotes**
```bash
$ user="deepak"
$ echo 'Hello, $user'
Hello, $user

$ echo "Hello, $user"
Hello, deepak

$ echo "Today is $(date +%Y-%m-%d)"
Today is 2026-08-08

$ echo 'Today is $(date +%Y-%m-%d)'
Today is $(date +%Y-%m-%d)
```

**3. The classic unquoted word-splitting bug**
```bash
$ mkdir "/tmp/my folder"
$ touch "/tmp/my folder/report.txt"
$ file="/tmp/my folder/report.txt"

$ ls $file
ls: cannot access '/tmp/my': No such file or directory
ls: cannot access 'folder/report.txt': No such file or directory

$ ls "$file"
/tmp/my folder/report.txt
```

**4. Command substitution — nesting and practical use**
```bash
$ echo "Kernel: $(uname -r), Hostname: $(hostname)"
Kernel: 6.8.0-generic, Hostname: platform-01

$ backup_dir="/backups/$(date +%Y%m%d)_$(hostname -s)"
$ echo "$backup_dir"
/backups/20260808_platform-01

$ count=$(ls /etc | wc -l)
$ echo "There are $count files in /etc"
There are 231 files in /etc
```

**5. Real-world: safely looping over `find` output (avoiding the word-split trap)**
```bash
$ find /var/log -name "*.log" -mtime +7 > /tmp/old_logs.txt
$ cat /tmp/old_logs.txt
/var/log/app one.log
/var/log/nginx/access.log

# WRONG — breaks on the filename with a space
$ for f in $(cat /tmp/old_logs.txt); do echo "Deleting: $f"; done
Deleting: /var/log/app
Deleting: one.log
Deleting: /var/log/nginx/access.log

# RIGHT — read line-by-line, quoted
$ while IFS= read -r f; do echo "Deleting: $f"; done < /tmp/old_logs.txt
Deleting: /var/log/app one.log
Deleting: /var/log/nginx/access.log
```

**6. Double quotes preserving formatting (e.g., multi-line variables)**
```bash
$ output=$(printf "Line1\nLine2\nLine3")
$ echo $output
Line1 Line2 Line3

$ echo "$output"
Line1
Line2
Line3
```

## Practice Questions

1. Why does `x = 5` fail in bash while `x=5` works? What error message do you get and why?
2. Given `path="/data/reports final"`, what's the output of `rm $path` vs `rm "$path"` if the directory has a trailing space in its name — and why is the unquoted version dangerous?
3. What's the difference between `` `date` `` and `$(date)`? Why is `$(...)` generally preferred in modern scripts?
4. You need to build a string like `Backup-<today's date>-<hostname>.tar.gz` for a nightly backup script. Write the line using command substitution.
5. Explain what happens (and why) when you run: `files='*.txt'; echo $files` inside a directory containing `a.txt` and `b.txt`, versus `echo "$files"`.
6. Write a snippet that safely iterates over every `*.log` file path in `/tmp/filelist.txt` (one path per line, some containing spaces) and prints each one, without breaking on spaces.
7. What does `IFS= read -r line` do differently from plain `read line`, and why is it the safe default for reading raw lines (e.g., file paths, CSV rows)?
8. A script does `result=$(some_command)` and later uses `$result` unquoted in an `if [ $result = "ok" ]` check — under what input could this break, and how would you fix it?
9. What's the output of `echo 'It'\''s a test'` and why is escaping a single quote inside single-quoted text tricky?
10. Why is `eval "$user_input"` dangerous in the context of quoting/substitution, and what's a safer alternative when you need dynamic command construction?

## Real Interview Questions (Company-Attributed)

- "How do you assign and print a variable in Bash?" — asked at *TCS*
- "What types of variables exist in shell scripting?" — asked at *Verizon*

## Interview Key Points

- **No spaces around `=`** in assignment — one of the most common beginner mistakes interviewers probe for.
- **Always double-quote variable expansions** (`"$var"`) unless you deliberately want word-splitting/glob-expansion — this single habit prevents the majority of real-world script bugs (spaces in filenames, empty variables).
- Single quotes = fully literal (no expansion at all). Double quotes = expand variables/command-substitution but suppress globbing/word-splitting of the *result*.
- `$(...)` over backticks: nests cleanly, more readable, POSIX-standard modern style — mention this as the "know the legacy vs modern" signal.
- Command substitution strips **trailing** newlines only — a gotcha when capturing multi-line command output and expecting it preserved exactly.
- Reading input safely: `while IFS= read -r line; do ... ; done < file` is the canonical safe pattern — interviewers love asking "how do you read a file line by line safely."
- Unquoted variable expansion during a `for var in $(...)` loop is a classic anti-pattern for iterating over filenames — know the `while read` alternative and `find -print0 | xargs -0` / `find -exec` for filenames with spaces or newlines.
