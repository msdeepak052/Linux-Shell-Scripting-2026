# Reading Input: `read` & Here-Strings

Getting data INTO a running script — from a user, a file, or another command's output.

## Explanation

`read` reads a line from stdin and splits it into variable(s):
```bash
read var1 var2 var3      # reads one line, splits on $IFS into the 3 vars (last var gets "the rest")
read -r var               # -r = raw: do NOT interpret backslashes as escapes (almost always want this)
read -p "Prompt: " var    # -p shows a prompt before reading
read -s password           # -s = silent (no echo to terminal) — for passwords
read -t 5 var               # -t = timeout in seconds
read -n 1 key                # -n = read exactly N characters, no Enter needed
read -a arr                  # -a = split the line into an array
```

**Here-strings** (`<<<`) feed a string to a command's stdin without a separate `echo | cmd` pipe:
```bash
read var <<< "some value"
```
This is more efficient than `echo "some value" | read var` — and importantly, `echo | read` runs `read` in a **subshell** (because of the pipe), so the variable is lost after the pipeline ends. Here-strings avoid that subshell trap entirely.

**Here-docs** (`<<EOF ... EOF`) feed multi-line text as stdin — covered in more depth in Stage 7, but commonly paired with `read` loops for inline test data.

The safe file-reading idiom you'll use constantly:
```bash
while IFS= read -r line; do
    ...
done < file.txt
```
`IFS=` prevents leading/trailing whitespace trimming, `-r` prevents backslash interpretation — together they read a line **exactly as-is**.

## Hands-On Examples

**1. Basic prompted input**
```bash
$ cat > greet.sh << 'EOF'
#!/bin/bash
read -p "Enter your name: " name
echo "Hello, $name!"
EOF
$ chmod +x greet.sh
$ ./greet.sh
Enter your name: Deepak
Hello, Deepak!
```

**2. The subshell trap: `echo | read` loses the variable**
```bash
$ echo "test123" | read value
$ echo "Value is: $value"
Value is:          # EMPTY — read ran in a subshell, variable didn't survive

$ read value <<< "test123"
$ echo "Value is: $value"
Value is: test123
```

**3. Silent input for passwords/secrets**
```bash
$ cat > login.sh << 'EOF'
#!/bin/bash
read -p "Username: " user
read -sp "Password: " pass
echo
echo "Logging in as $user (password length: ${#pass})"
EOF
$ chmod +x login.sh
$ ./login.sh
Username: deepak
Password: 
Logging in as deepak (password length: 10)
```

**4. Reading a file line-by-line the safe way**
```bash
$ cat servers.txt
web01.internal
web02.internal
db01.internal   # primary DB

$ while IFS= read -r host; do
>     echo "Pinging $host..."
> done < servers.txt
Pinging web01.internal...
Pinging web02.internal...
Pinging db01.internal...   # primary DB
```

**5. Reading a line into an array (splitting fields)**
```bash
$ line="deepak:x:1000:1000:Deepak K:/home/deepak:/bin/bash"
$ IFS=':' read -ra fields <<< "$line"
$ echo "Username: ${fields[0]}"
Username: deepak
$ echo "Home dir:  ${fields[5]}"
Home dir:  /home/deepak
$ echo "Shell:     ${fields[6]}"
Shell:     /bin/bash
```

**6. Real-world: interactive confirmation before a destructive action**
```bash
$ cat > cleanup.sh << 'EOF'
#!/bin/bash
read -p "This will delete all *.tmp files in /data. Continue? (y/N) " -n 1 confirm
echo
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "Proceeding with cleanup..."
    # find /data -name "*.tmp" -delete
else
    echo "Aborted."
    exit 1
fi
EOF
$ chmod +x cleanup.sh
$ ./cleanup.sh
This will delete all *.tmp files in /data. Continue? (y/N) y
Proceeding with cleanup...
```

**7. Timeout on read — useful in monitoring scripts waiting on manual override**
```bash
$ cat > wait_input.sh << 'EOF'
#!/bin/bash
if read -t 5 -p "Press Enter within 5s to abort deploy... " ; then
    echo "Deploy aborted by user."
else
    echo "No input received — proceeding with deploy."
fi
EOF
$ ./wait_input.sh
Press Enter within 5s to abort deploy... 
No input received — proceeding with deploy.
```

## Practice Questions

1. Why does `cat file.txt | read line; echo "$line"` print nothing, and what's the correct way to read the first line of `file.txt` into a variable?
2. Write a script that reads `/etc/passwd` line-by-line and prints just the usernames of accounts with UID >= 1000 (using `read` with `IFS=':'`, not `awk`).
3. What's the difference between `read line` and `IFS= read -r line`? Give an example input where the difference actually changes the output.
4. Write a script that prompts for a password using `read -s`, and confirms the length is at least 8 characters before proceeding.
5. How would you read a CSV line `"prod,web01,10.0.1.5,active"` into 4 separate variables in one `read` call?
6. What does `read -t 10 -p "Continue? " ans` do if the user doesn't type anything within 10 seconds — what's the exit status of `read` in that case, and how would you branch on it?
7. Explain why `<<<` (here-string) avoids the subshell problem that `command | read var` has.
8. Write a loop that reads `/tmp/hosts.txt` (one hostname per line, some lines may have trailing whitespace) and safely stores each into an array called `hosts`.
9. What happens if you `read a b` on the input line `one two three four`? Which variable gets what?
10. In a script meant to run **non-interactively** via cron, what happens if it hits a `read` call with no piped input — and how do you defensively avoid a script hanging in cron because of a leftover `read` prompt?

## Interview Key Points

- `echo "x" | read var` **does not work as expected** — the pipe creates a subshell, so `var` disappears once the pipeline exits. This is one of the most common "gotcha" interview questions on `read`.
- `<<<` (here-string) is the fix for the above — reads into the *current* shell, no subshell involved.
- `-r` flag matters: without it, backslashes in input get interpreted as escapes (e.g., a Windows-style path `C:\new\test` would get mangled) — always default to `read -r`.
- `IFS= read -r line` is the industry-standard idiom for reading files line-by-line exactly as written (no trimming, no escape interpretation) — expect to be asked to recite or use this pattern.
- `read -a` for splitting a line into an array; `IFS=':' read -ra fields <<< "$line"` is a very common real pattern for parsing `/etc/passwd`-style colon-delimited data.
- `read -t N` returns non-zero (timeout) if no input arrives in time — critical for writing scripts that shouldn't hang forever waiting on user input (e.g., automated pipelines with an optional manual-override window).
- Never leave a bare `read` (no `-t`, no default) in a script that might run unattended via cron/systemd — it will hang indefinitely waiting on stdin.
