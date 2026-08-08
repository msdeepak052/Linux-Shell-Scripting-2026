# Functions: Definition, Arguments, Return Values, Scope

Turning repeated logic into reusable, testable blocks — the building block of any real automation script.

## Explanation

**Definition** — two equivalent syntaxes:
```bash
function my_func {
    ...
}
# or (more portable, POSIX-compatible)
my_func() {
    ...
}
```

**Arguments**: functions receive their own positional parameters (`$1`, `$2`, `$@`, `$#`) — completely separate from the script's top-level `$1`/`$2`. Called just like a command: `my_func arg1 arg2`.

**Return values**: bash functions don't "return" data like other languages — `return N` only sets the function's **exit status** (0-255, same rules as script exit codes). To get actual **data** out of a function, you either:
1. `echo` the value and capture it with `$(my_func)` (command substitution) — the standard pattern for returning strings/numbers.
2. Assign to a global variable inside the function.
3. Use `local -n` (nameref, bash 4.3+) to write directly into a caller-provided variable.

**Scope**: variables are **global by default** in bash — a function can silently overwrite a variable used elsewhere in the script. Always declare function-local variables with `local` to avoid this.

## Hands-On Examples

**1. Basic function with arguments**
```bash
$ cat > funcs.sh << 'EOF'
#!/bin/bash
greet() {
    local name="$1"
    echo "Hello, $name!"
}

greet "Platform Team"
EOF
$ chmod +x funcs.sh
$ ./funcs.sh
Hello, Platform Team!
```

**2. `return` sets exit status, NOT a data value**
```bash
$ cat > check_even.sh << 'EOF'
#!/bin/bash
is_even() {
    local n="$1"
    if (( n % 2 == 0 )); then
        return 0    # success = "true"
    else
        return 1    # failure = "false"
    fi
}

for n in 4 7 10; do
    if is_even "$n"; then
        echo "$n is even"
    else
        echo "$n is odd"
    fi
done
EOF
$ ./check_even.sh
4 is even
7 is odd
10 is even
```

**3. Returning DATA from a function — via `echo` + command substitution**
```bash
$ cat > get_data.sh << 'EOF'
#!/bin/bash
get_free_disk_gb() {
    local mount="$1"
    df -BG --output=avail "$mount" | tail -1 | tr -dc '0-9'
}

free_space=$(get_free_disk_gb "/")
echo "Free space on /: ${free_space}G"

if (( free_space < 10 )); then
    echo "WARNING: Low disk space!"
fi
EOF
$ ./get_data.sh
Free space on /: 42G
```

**4. `local` scope — why it matters**
```bash
$ cat > scope_bug.sh << 'EOF'
#!/bin/bash
counter=0

increment_bad() {
    counter=$((counter + 1))   # no 'local' — modifies the GLOBAL counter
    echo "Inside function: $counter"
}

increment_bad
increment_bad
echo "After 2 calls: $counter"
EOF
$ ./scope_bug.sh
Inside function: 1
Inside function: 2
After 2 calls: 2         # global was mutated — sometimes desired, often a bug source

$ cat > scope_fixed.sh << 'EOF'
#!/bin/bash
total=100

process() {
    local total=0          # shadows the global — safe, isolated
    total=$((total + 5))
    echo "Local total inside function: $total"
}

process
echo "Global total unaffected: $total"
EOF
$ ./scope_fixed.sh
Local total inside function: 5
Global total unaffected: 100
```

**5. Functions calling functions, and `$?` chaining**
```bash
$ cat > deploy_pipeline.sh << 'EOF'
#!/bin/bash
run_tests() {
    echo "Running tests..."
    return 0
}

build_artifact() {
    echo "Building artifact..."
    return 0
}

deploy() {
    echo "Deploying..."
    return 0
}

main() {
    run_tests || { echo "Tests failed, aborting"; exit 1; }
    build_artifact || { echo "Build failed, aborting"; exit 1; }
    deploy || { echo "Deploy failed, aborting"; exit 1; }
    echo "Pipeline completed successfully"
}

main "$@"
EOF
$ ./deploy_pipeline.sh
Running tests...
Building artifact...
Deploying...
Pipeline completed successfully
```

**6. Real-world: a logging helper function used throughout a script**
```bash
$ cat > log_demo.sh << 'EOF'
#!/bin/bash
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
}

log INFO "Starting backup job"
log WARN "Disk usage above 80%"
log ERROR "Backup destination unreachable"
EOF
$ ./log_demo.sh
[2026-08-08 10:15:03] [INFO] Starting backup job
[2026-08-08 10:15:03] [WARN] Disk usage above 80%
[2026-08-08 10:15:03] [ERROR] Backup destination unreachable
```

**7. `local -n` nameref — writing back into a caller's variable (bash 4.3+)**
```bash
$ cat > nameref.sh << 'EOF'
#!/bin/bash
get_hostname_and_ip() {
    local -n result_ref=$1   # nameref to caller's variable name
    result_ref="$(hostname):$(hostname -I | awk '{print $1}')"
}

get_hostname_and_ip info
echo "Result: $info"
EOF
$ ./nameref.sh
Result: platform-01:10.0.1.42
```

## Practice Questions

1. Write a function `is_service_running()` that takes a service name, checks it with `systemctl is-active --quiet`, and returns 0/1 accordingly — then use it in an `if` statement.
2. Why doesn't `return "some string"` work the way you might expect in bash? What does `return` actually do, and what's the correct way to get string data out of a function?
3. Given a function that increments a variable named `counter` without using `local`, explain what bug this could cause if the same variable name is used elsewhere in a larger script.
4. Write a function `log()` that prefixes every message with a timestamp and a severity level (INFO/WARN/ERROR), callable as `log ERROR "disk full"`.
5. What's the difference between a function's `$1`/`$@` and the script's top-level `$1`/`$@`? Are they the same value?
6. Write a function `retry()` that takes a max-attempts count and a command (as remaining args) and retries the command until it succeeds or attempts run out — return its final exit status.
7. Explain how `local -n` (nameref) lets a function write a value back into a variable owned by the caller, with a short example.
8. What happens if you call a function before it's defined later in the same script? Does bash allow forward references like some other languages?
9. Write a function `main()` that calls three helper functions (`run_tests`, `build`, `deploy`) in sequence, aborting immediately if any one fails, then call it as `main "$@"` at the bottom of the script.
10. Why is it considered a bash best practice to declare ALL function-local variables with `local`, even ones that "probably" won't clash with anything else in the script?

## Interview Key Points

- **`return` only sets exit status (0-255)** — it is NOT a mechanism for returning arbitrary data; interviewers frequently ask "how do you return a string from a bash function" specifically to test whether you know to use `echo` + `$(func)` instead.
- **Variables are global by default** inside functions — always use `local` for function-scoped variables; this is one of the most common real-world bug sources in larger scripts (accidental variable clobbering between functions).
- Function arguments (`$1`, `$@`, `$#`) are **local to the function call**, separate from the script's own positional parameters — but functions still see the SAME global variables as the rest of the script (unless shadowed with `local`).
- `func_name() { ... }` (POSIX form) vs `function func_name { ... }` (bash-only form) — know both exist; prefer the POSIX form for portability.
- A logging helper function (`log LEVEL message`) using `shift` to consume the level and treat the rest as the message (`$*`) is an extremely common real-world pattern worth having memorized.
- `local -n` (namerefs) are a more advanced bash 4.3+ feature for "output parameters" — knowing they exist (even if rarely used) signals depth.
- Calling `main "$@"` as the very last line of a script (after defining all functions above it) is a widely recommended structuring convention — mention it as a sign of clean script architecture.
