# Conditionals: `if/elif/else`, `case`, `[ ]` vs `[[ ]]` vs `(( ))`

Branching logic — and the three different "test" syntaxes bash gives you, each with different rules.

## Explanation

### How `if/elif/else` actually works

```bash
if condition; then
    ...
elif other_condition; then
    ...
else
    ...
fi
```

The critical thing to internalize: **`condition` is not a special "boolean expression" — it is a normal command**, and `if` just looks at that command's **exit status**. `0` means "the command succeeded" → bash treats that as *true*. Any non-zero exit status means *false*. This is why `if grep -q "ERROR" file.log; then ...` works directly — `grep` itself IS the condition, no `[ ]` needed at all.

`[ ... ]`, `[[ ... ]]`, and `(( ... ))` are just three different **commands/constructs you can put in that condition slot** when you want to test something (string equality, file existence, a number comparison) rather than run a real program. Mechanically:

- `[ expr ]` — this is literally the `test` command; the closing `]` is just `test`'s last argument (yes, really — try `man test`). Because it's an ordinary command, ordinary word-splitting/globbing rules apply to whatever's inside, which is why unquoted variables break it.
- `[[ expr ]]` — this is bash **syntax**, parsed specially by the shell itself (not a command with arguments) — so it doesn't word-split or glob-expand unquoted variables, and it understands operators like `&&`, `||`, `<`, `>`, `=~` natively instead of needing them escaped or expressed as separate flags.
- `(( expr ))` — pure C-style arithmetic evaluation. Not for strings or files at all — only numbers.

Structural details worth knowing:
- `then` can go on the same line after a `;` (`if cond; then`) or on its own line (no `;` needed if it's on a new line) — purely a style choice, both are valid.
- `elif` chains as many times as you want; `else` is optional; every `if` must end with `fi`.
- You can nest `if` blocks freely, and you can combine multiple conditions inside one test using `&&`/`||` (inside `[[ ]]`) or by chaining separate `[[ ]] && [[ ]]` commands.
- A quick one-liner form exists too: `[[ -f "$file" ]] && echo "exists"` — no `if`/`fi` needed when you only have one action and don't need an `else` (this is just `if` replaced by the `&&` short-circuit operator, not a different feature).

| Syntax | What it is | Notes |
|---|---|---|
| `[ expr ]` | Alias for the `test` command (POSIX) | Word-splitting/globbing applies to unquoted vars inside — **must** quote variables (`[ "$x" = "y" ]`) or it breaks/errors on empty/multi-word values |
| `[[ expr ]]` | Bash keyword (not a command) | Safer: no word-splitting/globbing on unquoted vars, supports `&&`/`\|\|`/`<`/`>` directly, supports `=~` regex matching, supports pattern matching with `==` |
| `(( expr ))` | Arithmetic evaluation | For numeric comparisons: `((a > b))`, `((x++))`; returns exit status 0 if the arithmetic result is non-zero (true-ish) |

Common test operators: `-eq -ne -gt -lt -ge -le` (numeric), `= != -z -n` (string — `-z` empty, `-n` non-empty), `-f -d -e -r -w -x` (file tests: regular file, directory, exists, readable, writable, executable).

### Which one should you actually use? (Decision rule — stop second-guessing this)

You are writing **bash** scripts (shebang `#!/bin/bash` or `#!/usr/bin/env bash`), not portable `/bin/sh`. Under that (very common, modern) assumption, here is the simple default:

| Situation | Use | Why |
|---|---|---|
| **Any string test, file test, or logical condition** | **`[[ ... ]]`** | This is the modern default for 95% of conditionals in a bash script. Safer (no quoting landmines), more readable operators, supports regex. |
| **Any numeric/arithmetic comparison or math** | **`(( ... ))`** | Lets you write `(( cpu > 80 ))` instead of the clunkier `[[ $cpu -gt 80 ]]` — both work, but `(( ))` reads like normal math and is the idiomatic choice when *only* numbers are involved. |
| **Writing a script that must run under plain POSIX `sh`/`dash`** (e.g. Alpine Linux init scripts, `#!/bin/sh` scripts, some CI minimal-image contexts) | `[ ... ]` | `[[ ]]` and `(( ))` are bash-only extensions — `dash`/POSIX `sh` don't understand them and will error out. `[ ]` is the only one guaranteed portable. |

**In one sentence: if the shebang says `bash`, default to `[[ ]]` for conditions and `(( ))` for arithmetic, and only reach for `[ ]` when you specifically need POSIX-`sh` portability.** You'll still see `[ ]` constantly in older scripts, tutorials, and `/bin/sh`-based system scripts (like ones in `/etc/init.d`) — recognize it and know why it's written that way, but don't default to it yourself in new bash scripts.

### `case`

Pattern-matching switch — better than a long `if/elif` chain when testing ONE variable against multiple fixed patterns. Supports globs (`*`, `?`, `[abc]`) and `|` for OR-ing patterns. Does **not** fall through to the next pattern by default (each `;;` stops).

## Hands-On Examples

> **Reading these examples**: `$` is bash's normal prompt for a new command. When a command like `if...fi` or `case...esac` spans multiple lines and you type it directly into an interactive terminal, bash shows `>` as the **continuation prompt** on every line until the command is complete (i.e., until it sees the matching `fi`, `esac`, `done`, or closing quote). **The `>` is printed by bash itself, not something you type** — it's just the terminal telling you "still waiting for more input." If you paste these examples into a script file instead of typing them interactively, you'd write the same lines *without* any `>` at the start. Example 3 below shows this in action.

**1. `[ ]` vs `[[ ]]` — the unquoted-variable trap**
```bash
$ name=""
$ if [ $name = "admin" ]; then echo "match"; else echo "no match"; fi
bash: [: =: unary operator expected     # BROKEN — empty $name vanished, left "[ = admin ]"

$ if [ "$name" = "admin" ]; then echo "match"; else echo "no match"; fi
no match                                 # correct — quoting saved it

$ if [[ $name = "admin" ]]; then echo "match"; else echo "no match"; fi
no match                                 # [[ ]] handles unquoted empty var safely
```

**2. Numeric comparisons: `[ ]` vs `(( ))`**
```bash
$ cpu_usage=85
$ if [ "$cpu_usage" -gt 80 ]; then echo "High CPU: $cpu_usage%"; fi
High CPU: 85%

$ if (( cpu_usage > 80 )); then echo "High CPU: $cpu_usage%"; fi
High CPU: 85%

$ if [ "$cpu_usage" > 80 ]; then echo "wrong"; fi    # DANGER: > inside [ ] does STRING comparison / redirects!
```
`>` and `<` inside `[ ]` are shell redirection operators, not comparisons — `[ "$cpu_usage" > 80 ]` silently creates/overwrites a file named `80` in the current directory. Always use `-gt`/`-lt` with `[ ]`, or use `(( ))`/`[[ ]]` with real `>`/`<`.

**3. Regex matching with `[[ =~ ]]`**

Typed interactively (note the `>` continuation prompts bash prints automatically — you do not type these):
```bash
$ ip="10.0.1.5"
$ if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
>     echo "Valid IPv4 format"
> else
>     echo "Invalid"
> fi
Valid IPv4 format
```
The exact same logic saved inside a script file (`ip_check.sh`) — no `>` characters, because you're writing to a file, not typing live at a prompt:
```bash
#!/bin/bash
ip="10.0.1.5"
if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Valid IPv4 format"
else
    echo "Invalid"
fi
```
A one-liner version, no multi-line continuation needed at all:
```bash
$ email="deepak@company.com"
$ [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && echo "valid email"
valid email
```

**4. File test operators — a real health-check pattern**
```bash
$ config="/etc/myapp/config.yml"
$ if [[ -f "$config" && -r "$config" ]]; then
>     echo "Config exists and is readable"
> else
>     echo "Config missing or unreadable — aborting"
>     exit 1
> fi
Config exists and is readable

$ if [[ ! -d /var/log/myapp ]]; then
>     echo "Log dir missing, creating..."
>     mkdir -p /var/log/myapp
> fi
Log dir missing, creating...
```

**5. `case` statement — service-status style dispatch**
```bash
$ cat > svc.sh << 'EOF'
#!/bin/bash
read -p "Action (start/stop/restart/status): " action
case "$action" in
    start|Start)
        echo "Starting service..."
        ;;
    stop|Stop)
        echo "Stopping service..."
        ;;
    restart)
        echo "Restarting service..."
        ;;
    status)
        echo "Service is active"
        ;;
    *)
        echo "Unknown action: $action" >&2
        exit 1
        ;;
esac
EOF
$ chmod +x svc.sh
$ ./svc.sh
Action (start/stop/restart/status): restart
Restarting service...

$ ./svc.sh
Action (start/stop/restart/status): frobnicate
Unknown action: frobnicate
```

**6. `case` with glob patterns — dispatching on file extension**
```bash
$ cat > filetype.sh << 'EOF'
#!/bin/bash
file="$1"
case "$file" in
    *.log)
        echo "$file is a log file"
        ;;
    *.tar.gz|*.tgz)
        echo "$file is a compressed archive"
        ;;
    *.sh)
        echo "$file is a shell script"
        ;;
    *)
        echo "$file: unknown type"
        ;;
esac
EOF
$ ./filetype.sh backup-2026.tar.gz
backup-2026.tar.gz is a compressed archive
```

**7. Combining `&&`/`||` as lightweight conditionals**
```bash
$ [[ -f /etc/nginx/nginx.conf ]] && echo "nginx config present" || echo "nginx config missing"
nginx config present

$ systemctl is-active --quiet nginx && echo "nginx is running" || echo "nginx is DOWN"
nginx is running
```

## Practice Questions

1. Why does `[ $var = "test" ]` fail with `unary operator expected` when `$var` is unset or empty, but `[[ $var = "test" ]]` doesn't? What's the safe fix for `[ ]`?
2. What's wrong with `if [ "$count" > 10 ]; then ...`? What actually happens when this line executes, and what's the correct version?
3. Write an `if` chain that checks a variable `$env` and prints "Production", "Staging", or "Unknown environment" — then rewrite it as a `case` statement. Which is cleaner and why?
4. Write a health-check snippet using `[[ -f ... && -r ... ]]` that verifies a config file both exists and is readable before a script proceeds, exiting 1 with an error message otherwise.
5. Using `[[ =~ ]]`, write a check that validates a version string like `v2.3.1` matches the pattern `vMAJOR.MINOR.PATCH`.
6. What does `case` do differently from a chain of `if/elif` when you have 6 possible fixed string values to check against? Why might a senior engineer prefer `case` here?
7. Write a `case` statement that matches multiple patterns for one branch (e.g., both `yes` and `y` should trigger the same action).
8. What's the difference between `(( x > 5 ))` and `[ "$x" -gt 5 ]`? When would you prefer one over the other?
9. A script uses `[ -e "$file" ]` to check file existence, but a teammate says it should be `[ -f "$file" ]` instead — what's the actual difference, and when does it matter?
10. Explain what `[[ -n "$var" ]]` vs `[[ -z "$var" ]]` test, and rewrite `if [ "$var" != "" ]` using one of them.

## Real Interview Questions (Company-Attributed)

- "Write a script to check whether a given IP address is a valid IPv4 address." — asked at *Akamai*

## Interview Key Points

- **Default rule to stop the confusion**: in a `#!/bin/bash` script, use `[[ ]]` for string/file/logical tests and `(( ))` for arithmetic — always. Only drop to `[ ]` if the script must run under POSIX `sh`/`dash` (no bashisms allowed). State this decision rule directly if asked "which should I use" — it's exactly the kind of clear, opinionated answer that reads as senior-level, versus listing all three with no recommendation.
- **`[ ]` is a command (`test`), `[[ ]]` is a bash keyword** — this is *the* foundational fact interviewers check; it explains every other difference (word-splitting, why `&&`/`||` work directly inside `[[ ]]` but not `[ ]`, why `[[ ]]` doesn't need every variable quoted).
- `>` and `<` inside `[ ]` mean shell redirection, not comparison — a genuinely dangerous gotcha (can silently create files) and a favorite "spot the bug" interview question.
- Always quote variables inside `[ ]`; `[[ ]]` is more forgiving but quoting is still best practice for consistency and to handle glob characters correctly.
- `(( ))` is for **arithmetic only** — cleanest for numeric comparisons and increment/decrement (`((i++))`); returns false (exit 1) if the result evaluates to 0.
- `case` beats a long `if/elif` chain readability-wise once you're matching **one variable** against **3+ fixed patterns/globs** — know this as the "when to use case" talking point.
- `case` does not fall through by default (unlike C `switch`) — each pattern block ends with `;;`; `;&` (fall through unconditionally) and `;;&` (continue testing next patterns) exist in bash 4+ but are rarely used — worth mentioning you know they exist.
- `[[ =~ ]]` enables extended regex matching directly in a condition — a key differentiator from POSIX `[ ]`, commonly used for input validation (IPs, versions, emails) in real scripts.
