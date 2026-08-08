# Loops: `for`, `while`, `until`, `break`/`continue`

Repetition — over lists, over files, over conditions, over "forever until something happens."

## Explanation

**`for`** — iterate over a known list (words, files, ranges, command output):
```bash
for item in list; do ... done
for (( i=0; i<10; i++ )); do ... done     # C-style, for numeric ranges
for i in {1..10}; do ... done              # brace expansion range
```

**`while`** — loop **while** a condition stays true; used for "keep checking until X happens" or reading input streams:
```bash
while condition; do ... done
```

**`until`** — the inverse of `while`; loops **until** a condition becomes true (i.e., while it's false):
```bash
until condition; do ... done
```
`until` is rarer in practice but idiomatic for "wait until service is up" style polling.

**`break`** exits the loop entirely. **`continue`** skips to the next iteration. Both accept an optional numeric argument (`break 2`) to break out of N nested loops.

Key production gotcha: `command | while read ...` runs the `while` in a **subshell** (because of the pipe) — variables set/incremented inside won't persist after the loop. Use **process substitution** (`while read ...; done < <(command)`) or redirect from a file to avoid this.

## Hands-On Examples

**1. Basic `for` over a list**
```bash
$ for env in dev staging prod; do
>     echo "Deploying to $env"
> done
Deploying to dev
Deploying to staging
Deploying to prod
```

**2. `for` over files (globbing)**
```bash
$ ls /var/log/*.log
/var/log/app.log  /var/log/nginx.log  /var/log/syslog.log

$ for f in /var/log/*.log; do
>     size=$(du -h "$f" | cut -f1)
>     echo "$f -> $size"
> done
/var/log/app.log -> 4.2M
/var/log/nginx.log -> 128M
/var/log/syslog.log -> 890K
```

**3. C-style `for` and range loops**
```bash
$ for (( i=1; i<=5; i++ )); do
>     echo "Attempt $i of 5"
> done
Attempt 1 of 5
Attempt 2 of 5
Attempt 3 of 5
Attempt 4 of 5
Attempt 5 of 5

$ for port in {8080..8083}; do
>     echo "Checking port $port"
> done
Checking port 8080
Checking port 8081
Checking port 8082
Checking port 8083
```

**4. `while` — polling until a service responds (real ops pattern)**
```bash
$ cat > wait_for_service.sh << 'EOF'
#!/bin/bash
retries=0
max_retries=5
until curl -sf http://localhost:8080/health > /dev/null; do
    retries=$((retries + 1))
    if (( retries >= max_retries )); then
        echo "Service failed to come up after $max_retries attempts" >&2
        exit 1
    fi
    echo "Waiting for service... attempt $retries/$max_retries"
    sleep 2
done
echo "Service is up!"
EOF
$ ./wait_for_service.sh
Waiting for service... attempt 1/5
Waiting for service... attempt 2/5
Service is up!
```

**5. `while read` reading a file (safe pattern) vs the subshell pipe trap**
```bash
$ cat servers.txt
web01
web02
web03

# BROKEN — pipe creates a subshell, $count is lost after the loop
$ count=0
$ cat servers.txt | while read -r host; do count=$((count+1)); done
$ echo "Processed: $count"
Processed: 0

# FIXED — process substitution keeps the while loop in the current shell
$ count=0
$ while read -r host; do count=$((count+1)); done < <(cat servers.txt)
$ echo "Processed: $count"
Processed: 3

# ALSO FIXED — simple input redirection
$ count=0
$ while read -r host; do count=$((count+1)); done < servers.txt
$ echo "Processed: $count"
Processed: 3
```

**6. `break` and `continue` — skipping and early exit**
```bash
$ for host in web01 web02 db01 web03 cache01; do
>     [[ "$host" == db* ]] && continue          # skip DB hosts
>     [[ "$host" == cache01 ]] && break          # stop entirely at cache01
>     echo "Restarting app on $host"
> done
Restarting app on web01
Restarting app on web02
Restarting app on web03
```

**7. Real-world: retry-with-backoff wrapper for a flaky command**
```bash
$ cat > retry.sh << 'EOF'
#!/bin/bash
max=5
delay=1
for (( attempt=1; attempt<=max; attempt++ )); do
    if curl -sf https://api.example.com/deploy -X POST; then
        echo "Deploy triggered successfully on attempt $attempt"
        exit 0
    fi
    echo "Attempt $attempt failed, retrying in ${delay}s..."
    sleep "$delay"
    delay=$((delay * 2))   # exponential backoff
done
echo "All $max attempts failed" >&2
exit 1
EOF
```

**8. `until` — waiting for a file to appear (e.g., a lock/flag file from another process)**
```bash
$ cat > wait_flag.sh << 'EOF'
#!/bin/bash
until [[ -f /tmp/ready.flag ]]; do
    echo "Waiting for /tmp/ready.flag..."
    sleep 1
done
echo "Flag detected, proceeding."
EOF
```

## Practice Questions

1. Write a `for` loop that iterates over all `.log` files in `/var/log`, and for each one prints its size in human-readable form.
2. Explain why `cat file.txt | while read -r line; do count=$((count+1)); done; echo $count` always prints an unchanged/zero `$count`, and rewrite it so the count is correct.
3. Write a `while` loop that polls `curl -sf http://localhost/health` every 2 seconds, up to a maximum of 10 attempts, exiting with an error if the service never comes up.
4. What's the difference between `until condition; do ... done` and `while ! condition; do ... done`? Are they functionally equivalent?
5. Write a nested loop over environments (`dev staging prod`) and services (`api worker cache`) that prints `Restarting <service> in <env>`, but skips the `cache` service entirely in `prod` using `continue`.
6. What does `break 2` do inside a doubly-nested loop, and give an example scenario where you'd need it.
7. Write a retry loop with exponential backoff (1s, 2s, 4s, 8s...) for a command that might transiently fail, capping at 5 attempts.
8. Convert this brace-expansion loop `for i in {1..5}; do echo $i; done` into an equivalent C-style `for (( ))` loop.
9. You need to process a file where lines might contain leading/trailing spaces that must be preserved exactly, and the file might not end with a trailing newline — how do you write the `while read` loop to handle both correctly?
10. Why would you use `while read -r line; do ... done < <(command)` (process substitution) instead of `command | while read -r line; do ... done` when the loop body needs to set variables used after the loop?

## Real Interview Questions (Company-Attributed)

- "Write a shell script to sum numbers from 1 to 100." — asked at *Perfios*
- "Write a shell script that takes an integer N and prints numbers in a triangular pattern (each row printed in reverse order, with the number of elements increasing by one per row)." — asked at *Perfios*
- "Reverse a string / check whether it's a palindrome using a `for` loop." — asked at *Sigmoid*
- "Write a script that renames all `.txt` files in a directory by appending the current date to the filename." — asked at *an unnamed company (via community-sourced interview notes)*
- "Write a shell script to capture the names of files being created in a directory and store them in a file." — asked at *an unnamed company (via community-sourced interview notes)*

## Interview Key Points

- **The `command | while read` subshell trap** is one of the most-asked "why doesn't my counter work" bash interview questions — always know process substitution (`< <(command)`) or plain file redirection as the fix.
- `for...in` is for **known/finite lists** (files, words, ranges); `while` is for **condition-driven** repetition (polling, reading streams) — articulating this distinction is itself a good interview answer.
- `break N` / `continue N` for nested loops — lesser-known but a good "I know the details" signal.
- Exponential backoff retry loops are a extremely common real-world pattern to be asked to write live in a platform engineering interview — practice writing this from memory.
- `until` is functionally `while !` — know it exists but that `while` with a negated/inverted condition is more commonly seen in real codebases; `until` is more idiomatic for "wait until ready" polling.
- `{1..10}` brace expansion happens at **parse time** (before the loop runs) and doesn't support variables directly (`{1..$n}` doesn't expand as expected) — for a variable-bounded range, use C-style `for (( i=1; i<=n; i++ ))` or `seq`.
- Infinite loops (`while true; do ... done` or `while :; do ... done`) combined with `sleep` + `break` on a condition is the standard shape of a polling/daemon-style script — recognize `:` as a no-op "true" builtin.
