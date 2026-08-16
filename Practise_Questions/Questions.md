# Top 20 Bash Scripting Coding Questions

| #      | Coding question                                                                                    | Topics tested                             |
| ------ | -------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| **1**  | Write a script to check whether a file exists, is readable, writable, and executable.              | `if`, file tests                          |
| **2**  | Write a script to find the largest of 3 numbers.                                                   | Variables, `if/elif`, arithmetic          |
| **3**  | Write a script to check whether a number is even or odd.                                           | Arithmetic, `%`, conditions               |
| **4**  | Write a script to reverse a string.                                                                | Variables, loops, string manipulation     |
| **5**  | Write a script to check whether a string is a palindrome.                                          | Strings, loops, conditions                |
| **6**  | Write a script to count the number of lines, words, and characters in a file.                      | `wc`, command substitution                |
| **7**  | Write a script to find the top 5 largest files in a directory.                                     | `find`, `du`, sorting, pipes              |
| **8**  | Write a script to find all `.log` files modified in the last 24 hours.                             | `find`, conditions                        |
| **9**  | Write a script to search for a particular string in all `.log` files and print matching lines.     | `grep`, loops, files                      |
| **10** | Write a script to count how many times each IP address occurs in a log file.                       | `awk`, associative arrays                 |
| **11** | Write a script to find the most frequently occurring word in a file.                               | `awk`, `sort`, `uniq`                     |
| **12** | Given a CSV with duplicate keys, aggregate/sum values for each key.                                | `awk`, associative arrays                 |
| **13** | Write a script to validate an IPv4 address.                                                        | Regex, `awk`, conditions                  |
| **14** | Write a script to check whether a process is running and restart it if it is not.                  | `ps`, `pgrep`, exit status                |
| **15** | Write a script to monitor disk usage and alert if usage exceeds 80%.                               | `df`, arithmetic, conditions              |
| **16** | Write a script to monitor CPU/memory usage and print an alert when a threshold is crossed.         | `top`, `ps`, `/proc`, conditions          |
| **17** | Write a script to find failed SSH login attempts from `/var/log/auth.log`.                         | `grep`, `awk`, log parsing                |
| **18** | Write a script that accepts command-line arguments and validates them.                             | `$1`, `$2`, `$#`, `$@`, `shift`           |
| **19** | Write a script using a function to check whether a given URL/service is reachable.                 | Functions, `curl`, exit status            |
| **20** | Write a production-style script to check multiple servers/services and report which ones are DOWN. | Arrays, loops, functions, SSH, exit codes |

---

# The 20 Questions You Should Practice

### 1. File validation

**Question:**

Write a Bash script that accepts a filename and checks:

* Does the file exist?
* Is it readable?
* Is it writable?
* Is it executable?

You should know:

```bash
-f
-r
-w
-x
```

---

### 2. Find largest of 3 numbers

Example:

```text
Enter numbers: 10 25 15

Largest: 25
```

You should be comfortable with:

```bash
if
elif
else
```

and:

```bash
$(( ))
```

---

### 3. Even or odd

```text
Enter number: 17

17 is odd
```

Core concept:

```bash
if (( num % 2 == 0 ))
```

This is a very common beginner/intermediate question.

---

### 4. Reverse a string

```text
Input: hello
Output: olleh
```

Possible approaches:

```bash
rev
```

or manually using a loop.

**Interview follow-up:**
"Can you do it without using `rev`?"

---

### 5. Palindrome

```text
Input: madam
Output: Palindrome
```

Example inputs:

```text
madam     → Palindrome
level     → Palindrome
hello     → Not palindrome
```

This tests string manipulation and conditions.

---

### 6. File statistics

Given:

```text
server.log
```

Print:

```text
Lines      : 500
Words      : 3200
Characters : 25000
```

You should know:

```bash
wc -l
wc -w
wc -c
```

Also understand:

```bash
$(command)
```

---

### 7. Top 5 largest files

Given a directory:

```text
/home/app/logs
```

Find the 5 largest files.

Typical tools:

```bash
find
du
sort
head
```

Interviewers may ask:

> What happens if filenames contain spaces?

That's where proper quoting becomes important.

---

### 8. Find recently modified logs

**Question:**

Find `.log` files modified within the last 24 hours.

Expected knowledge:

```bash
find
-mtime
```

For example, understand the difference between:

```bash
-mtime
-mmin
```

---

### 9. Search logs

Given:

```text
application.log
```

Find all occurrences of:

```text
ERROR
```

and print:

```text
timestamp + error message
```

You should know:

```bash
grep
grep -i
grep -n
grep -v
```

and pipes:

```bash
|
```

---

# 10. Count IP addresses in logs

This is **very important for DevOps interviews**.

Given:

```text
10.0.0.1 GET /index.html
10.0.0.2 GET /login
10.0.0.1 GET /home
10.0.0.3 GET /api
10.0.0.1 GET /test
```

Output:

```text
10.0.0.1  3
10.0.0.2  1
10.0.0.3  1
```

You should know:

```bash
awk
```

and especially:

```awk
count[$1]++
```

This is one of the most useful Bash interview patterns.

---

# 11. Most frequent word

Given:

```text
error warning error success error warning
```

Output:

```text
error 3
warning 2
```

This tests:

```bash
tr
sort
uniq -c
awk
```

and pipelines.

---

# 12. CSV aggregation

This is **highly relevant to DevOps automation**.

Input:

```csv
key,value
apple,10
banana,20
apple,30
orange,5
banana,15
```

Output:

```text
apple   40
banana  35
orange  5
```

The important Bash/`awk` concept is:

```awk
sum[$1] += $2
```

You should also understand CSV field separation:

```bash
awk -F,
```

---

# 13. IPv4 validation

Input:

```text
192.168.1.10
```

Output:

```text
Valid IPv4
```

Input:

```text
192.168.1.300
```

Output:

```text
Invalid IPv4
```

This tests:

* `read`
* `if`
* regex
* `awk`
* loops
* numeric comparison

And it's a good interview question because a simple regex alone is **not enough** to properly validate IPv4 ranges.

---

# 14. Process monitoring

**Question:**

Check whether `nginx` is running.

If running:

```text
nginx is running
```

If not:

```text
nginx is not running
Starting nginx...
```

You should know:

```bash
pgrep
ps
systemctl
$?
```

Example concepts:

```bash
pgrep nginx
```

and:

```bash
if command; then
```

---

# 15. Disk usage monitoring

Very common **real-world DevOps question**.

If `/` usage is greater than 80%:

```text
WARNING: Disk usage is 85%
```

Otherwise:

```text
Disk usage is normal: 65%
```

You should know:

```bash
df -h
```

and extracting values using:

```bash
awk
```

Then:

```bash
if (( usage > 80 ))
```

---

# 16. CPU/Memory monitoring

Example:

```text
CPU Usage: 92%
Memory Usage: 87%

WARNING: High resource utilization
```

Possible tools:

```bash
top
ps
free
awk
```

A good interviewer may follow up:

> "How would you make this script run every 5 minutes?"

Answer:

```text
cron
```

---

# 17. Failed SSH login detection

Given:

```text
/var/log/auth.log
```

Find failed SSH login attempts.

Example output:

```text
Failed attempts: 25

192.168.1.20  10
192.168.1.30  8
192.168.1.40  7
```

This combines:

```bash
grep
awk
sort
uniq
```

This is an excellent **production troubleshooting** question.

---

# 18. Command-line arguments

Write:

```bash
./script.sh file.txt 80
```

where:

```text
$1 = file.txt
$2 = 80
```

Your script should validate:

```text
Usage: ./script.sh <file> <threshold>
```

You should know:

```bash
$0
$1
$2
$#
$@
$?
```

and preferably:

```bash
shift
```

Interview follow-up:

> What's the difference between `$@` and `$*`?

You should be able to answer this.

---

# 19. Function + service health check

Create:

```bash
check_service()
```

which accepts:

```text
hostname
port
```

Example:

```text
check_service google.com 443
```

Output:

```text
google.com:443 is reachable
```

Possible tool:

```bash
curl
```

or:

```bash
nc
```

This tests **functions + arguments + exit codes**.

---

# 20. Multi-server health check ⭐

This is the one I would especially prepare for a **Senior Platform/DevOps interview**.

Input:

```text
servers.txt
```

```text
server1
server2
server3
```

Script:

```text
Checking server1...
server1: UP

Checking server2...
server2: DOWN

Checking server3...
server3: UP
```

You should be able to build it using:

```bash
while read
for
function
ssh
ping
curl
$?
```

Then improve it:

```text
Total servers : 10
UP            : 8
DOWN          : 2
```

Then interviewer may ask:

> "How would you run checks in parallel?"

That's where you should know:

```bash
&
wait
```

---

# ⭐ Topics You MUST Know Before the Interview

Don't just memorize these 20 programs. Make sure you can code using these Bash concepts:

### Level 1 — Basics

```bash
#!/bin/bash

variables
read
echo
printf
comments
```

### Level 2 — Conditions

```bash
if
elif
else

[[ ]]
(( ))

-e
-f
-d
-r
-w
-x
```

### Level 3 — Loops

```bash
for
while
until
```

and:

```bash
break
continue
```

### Level 4 — Strings

Know:

```bash
${#str}
${str:0:5}
${str//old/new}
```

and:

```bash
=~
```

for regex matching.

### Level 5 — Arrays

Know both:

```bash
arr=(a b c)
```

and associative arrays:

```bash
declare -A count
```

Very important for:

```bash
awk
```

style aggregation problems.

### Level 6 — Functions

Be comfortable with:

```bash
function_name() {
    ...
}
```

arguments:

```bash
$1
$2
```

and return status:

```bash
return 0
return 1
```

---

# ⭐ Most Important DevOps Bash Commands

You should be able to combine these without thinking too much:

```text
grep
awk
sed
sort
uniq
cut
tr
xargs
find
wc
head
tail
tee
cat
printf
```

System commands:

```text
ps
top
free
df
du
uptime
systemctl
journalctl
```

Networking:

```text
curl
wget
ping
ssh
scp
nc
ss
```

---

# 🔥 The Interviewer's Favorite Bash Concepts

Expect follow-up questions around these:

```bash
$?
$#
$@
$*
$0
$!
$$
```

Especially:

### `$?`

Exit status of the previous command.

```bash
ls /tmp

echo $?
```

### `$#`

Number of arguments.

```bash
./script.sh a b c

echo $#
```

Output:

```text
3
```

### `$@`

All positional arguments.

### `$!`

PID of the most recently started background process.

### `$$`

PID of the current shell/script.

---

# 🎯 If You Have Limited Time

For a **Senior DevOps / Platform Engineer interview**, prioritize these 10:

**1.** Disk usage monitoring
**2.** Process/service monitoring
**3.** Log parsing with `grep + awk`
**4.** IP address counting
**5.** CSV aggregation
**6.** Find largest files
**7.** Command-line argument handling
**8.** Multi-server health check
**9.** String/palindrome manipulation
**10.** Parallel execution using `&` + `wait`

If you can **write these from scratch without looking at the answer**, you'll be in a much stronger position for Bash coding rounds.

---

## Real Company-Asked Coding Questions (21+)

These are actual coding/scripting questions pulled from the `Company-Attributed` interview-question sections across the `Stage-*` folders — i.e. questions a named or documented company genuinely asked, not generic practice material. Pure theory/definition questions (e.g. "What is a PID?", "Explain `lsof`") were excluded — only tasks that require writing a script/command are listed.

| #      | Coding question                                                                                                                                             | Asked at              | Source                                                                        |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | ------------------------------------------------------------------------------ |
| **21** | Write a Unix command to find the `ERROR` keyword in a text file, case-insensitively.                                                                          | Akamai                 | Stage-1-Core-CLI-Skills/05-Text-Processing-Basics-Grep-Cut-Sort-Uniq-Tr-Wc.md   |
| **22** | Write a Bash command to get the total number of lines in a file.                                                                                               | Unnamed company        | Stage-1-Core-CLI-Skills/05-Text-Processing-Basics-Grep-Cut-Sort-Uniq-Tr-Wc.md   |
| **23** | Write a Unix command to find all files with size greater than 1 GB.                                                                                            | Akamai                 | Stage-1-Core-CLI-Skills/07-Searching-Find-Locate-Which-Whereis-Type.md         |
| **24** | Write a script to find all files in the current directory and subdirectories modified more than 5 hours ago but not beyond today.                             | Sigmoid                | Stage-1-Core-CLI-Skills/07-Searching-Find-Locate-Which-Whereis-Type.md         |
| **25** | Write a script to count how many processes are running under a given user (e.g. `ubuntu`).                                                                    | Nitor Infotech         | Stage-2-Process-System-Management/01-Process-Fundamentals-Ps-Top-Htop.md       |
| **26** | Write a cron expression to schedule a job in Linux.                                                                                                            | Oracle                  | Stage-2-Process-System-Management/09-Scheduling-Cron-At-Systemd-Timers.md      |
| **27** | Write a shell script where VM `ubuntu1` has auto-SSH enabled (`ssh -i` with a private key) and copies a directory (`/nobackup`) to another VM.                | Cisco                   | Stage-4-Networking/06-SSH-Key-Auth-Agent-Config-Tunneling-Scp-Rsync.md         |
| **28** | Write a script to monitor a directory and automatically copy new files to a remote server using SCP.                                                          | Cisco                   | Stage-4-Networking/06-SSH-Key-Auth-Agent-Config-Tunneling-Scp-Rsync.md         |
| **29** | Write a script to check if an external API is reachable before making a request.                                                                              | Turning                 | Stage-4-Networking/07-Network-Troubleshooting-Ping-Traceroute-Curl-Tcpdump.md  |
| **30** | Write a script to check whether a given IP address is a valid IPv4 address.                                                                                    | Akamai                  | Stage-6-Shell-Scripting-Fundamentals/05-Conditionals-If-Case.md                |
| **31** | Write a shell script to sum numbers from 1 to 100.                                                                                                             | Perfios                 | Stage-6-Shell-Scripting-Fundamentals/06-Loops.md                               |
| **32** | Write a shell script that takes an integer N and prints numbers in a triangular pattern (each row printed in reverse order, elements increasing by one per row). | Perfios              | Stage-6-Shell-Scripting-Fundamentals/06-Loops.md                               |
| **33** | Reverse a string / check whether it's a palindrome using a `for` loop.                                                                                         | Sigmoid                 | Stage-6-Shell-Scripting-Fundamentals/06-Loops.md                               |
| **34** | Write a script that renames all `.txt` files in a directory by appending the current date to the filename.                                                    | Unnamed company         | Stage-6-Shell-Scripting-Fundamentals/06-Loops.md                               |
| **35** | Write a shell script to capture the names of files being created in a directory and store them in a file.                                                     | Unnamed company         | Stage-6-Shell-Scripting-Fundamentals/06-Loops.md                               |
| **36** | Write a script to search a log file for the patterns `error` and `warning`, storing error lines in one file and warning lines in another, with the filename passed as an argument. | EPAM  | Stage-7-Advanced-Shell-Scripting/01-Advanced-Sed-Awk-Scripting.md              |
| **37** | Write a script to find a particular name/word in a file and replace it with another word.                                                                     | Sigmoid                 | Stage-7-Advanced-Shell-Scripting/01-Advanced-Sed-Awk-Scripting.md              |
| **38** | Write a script to find the first occurrence of a pattern in a file and extract the full matching line.                                                        | Sigmoid                 | Stage-7-Advanced-Shell-Scripting/01-Advanced-Sed-Awk-Scripting.md              |
| **39** | Given a real-time app log with lines like `Connection established from: <IP>`, write a script that returns all unique IP addresses and their total count.    | Sigmoid                 | Stage-7-Advanced-Shell-Scripting/01-Advanced-Sed-Awk-Scripting.md              |
| **40** | Write a script that reads a log with `ERROR`/`INFO` lines and raises an alert if the same error message occurs more than 3 times.                             | Sigmoid                 | Stage-7-Advanced-Shell-Scripting/01-Advanced-Sed-Awk-Scripting.md              |
| **41** | Write a Bash script for log analysis.                                                                                                                          | Unnamed company         | Stage-7-Advanced-Shell-Scripting/01-Advanced-Sed-Awk-Scripting.md              |
| **42** | Write a script to check disk usage and send an alert if it exceeds a threshold.                                                                                | Nextturn                | Stage-8-Production-Grade-Scripting-Automation/01-Health-Check-Monitoring-Alerting-Scripts.md |
| **43** | Create a script to monitor disk usage; if it exceeds 80%, log the details to a file and send an alert email.                                                  | Unnamed company         | Stage-8-Production-Grade-Scripting-Automation/01-Health-Check-Monitoring-Alerting-Scripts.md |
| **44** | Write a shell script that checks if a service is running, restarts it if not, and logs the event.                                                             | Unnamed company         | Stage-8-Production-Grade-Scripting-Automation/01-Health-Check-Monitoring-Alerting-Scripts.md |
| **45** | Write a script to monitor a service and restart it if it fails, including proper logging.                                                                     | LTIMindtree             | Stage-8-Production-Grade-Scripting-Automation/01-Health-Check-Monitoring-Alerting-Scripts.md |
| **46** | Write a shell script to find and delete all files in a directory older than 30 days.                                                                           | Unnamed company         | Stage-8-Production-Grade-Scripting-Automation/02-Backup-Cleanup-Log-Rotation-Automation.md |
| **47** | Write a script to delete files older than 10 days.                                                                                                             | IBM                     | Stage-8-Production-Grade-Scripting-Automation/02-Backup-Cleanup-Log-Rotation-Automation.md |
| **48** | Write a shell script to delete log files older than 30 days.                                                                                                   | Sigmoid                 | Stage-8-Production-Grade-Scripting-Automation/02-Backup-Cleanup-Log-Rotation-Automation.md |
| **49** | Write a shell script to back up logs from the last 7 days and remove older ones.                                                                               | Qentelli Solutions      | Stage-8-Production-Grade-Scripting-Automation/02-Backup-Cleanup-Log-Rotation-Automation.md |
| **50** | Write a shell script that compresses logs older than 30 days and deletes logs older than 90 days, scheduled daily via cron.                                   | Unnamed company         | Stage-8-Production-Grade-Scripting-Automation/02-Backup-Cleanup-Log-Rotation-Automation.md |

> "Unnamed company" = the source file attributes the question to "an unnamed company (via community-sourced interview notes)" rather than a named employer — still a real, documented interview question, just without a confirmed company name.
