# **AWK hands-on/interviews**

## 1. First understand how AWK works

Suppose `data.txt` contains:

```text
101 Alice 50000
102 Bob   60000
103 John  55000
104 Ravi  70000
```

Basic AWK:

```bash
awk '{print $1, $2, $3}' data.txt
```

Output:

```text
101 Alice 50000
102 Bob 60000
103 John 55000
104 Ravi 70000
```

Here:

| AWK term | Meaning                                 |
| -------- | --------------------------------------- |
| `$0`     | Entire current line                     |
| `$1`     | First field                             |
| `$2`     | Second field                            |
| `$3`     | Third field                             |
| `NF`     | Number of fields in current line        |
| `NR`     | Current record/line number              |
| `FNR`    | Current line number within current file |

These are the **most important built-in variables**.

---

# 2. `$0` — Entire line

```bash
awk '{print $0}' data.txt
```

Output:

```text
101 Alice 50000
102 Bob 60000
103 John 55000
104 Ravi 70000
```

So:

```text
$0 = entire line
```

Example:

```bash
awk '{print "Line:", $0}' data.txt
```

Output:

```text
Line: 101 Alice 50000
Line: 102 Bob 60000
...
```

---

# 3. `$1`, `$2`, `$3` — Fields

```bash
awk '{print $1}' data.txt
```

Output:

```text
101
102
103
104
```

```bash
awk '{print $2}' data.txt
```

Output:

```text
Alice
Bob
John
Ravi
```

Think:

```text
101 Alice 50000
│   │     │
│   │     └── $3
│   └──────── $2
└──────────── $1
```

---

# 4. `NF` — Number of Fields

`NF` tells you **how many columns/fields are present in the current line**.

```bash
awk '{print NF}' data.txt
```

Output:

```text
3
3
3
3
```

Very useful:

```bash
awk '{print $NF}' data.txt
```

`$NF` means:

> The last field.

For:

```text
101 Alice 50000
```

`NF = 3`

Therefore:

```text
$NF = $3 = 50000
```

Example:

```bash
awk '{print $1, $NF}' data.txt
```

Output:

```text
101 50000
102 60000
103 55000
104 70000
```

### Important interview point

```text
NF  → number of fields
$NF → value of the last field
```

---

# 5. `NR` — Number of Records

`NR` means **Number of Records processed so far**.

Usually, when reading a normal text file:

```text
NR = line number
```

Example:

```bash
awk '{print NR, $0}' data.txt
```

Output:

```text
1 101 Alice 50000
2 102 Bob 60000
3 103 John 55000
4 104 Ravi 70000
```

So:

```text
NR
1
2
3
4
```

### Common use

Print line numbers:

```bash
awk '{print NR ":" $0}' data.txt
```

---

# 6. `FNR` — File Record Number

This is slightly different from `NR`.

Suppose:

`file1.txt`

```text
Alice
Bob
```

`file2.txt`

```text
John
Ravi
```

Run:

```bash
awk '{print NR, FNR, $0}' file1.txt file2.txt
```

Output:

```text
1 1 Alice
2 2 Bob
3 1 John
4 2 Ravi
```

Notice:

```text
NR   = keeps increasing across files

FNR  = resets for every file
```

### Easy way to remember

```text
NR  → overall line number
FNR → file-specific line number
```

Very common pattern:

```bash
awk 'NR == FNR { ... }' file1 file2
```

This is used when comparing or joining two files.

---

# 7. `BEGIN`

`BEGIN` executes **before AWK starts reading the input**.

Example:

```bash
awk 'BEGIN {print "Starting AWK"} {print $1}' data.txt
```

Output:

```text
Starting AWK
101
102
103
104
```

So the execution order is:

```text
BEGIN
   ↓
Read line 1
   ↓
Read line 2
   ↓
Read line 3
   ↓
...
```

### Typical use

Initialize variables:

```bash
awk 'BEGIN {sum=0} {sum += $3} END {print sum}' data.txt
```

We'll come to this important pattern shortly.

---

# 8. `END`

`END` executes **after all input has been processed**.

Example:

```bash
awk '{print $2} END {print "Finished"}' data.txt
```

Output:

```text
Alice
Bob
John
Ravi
Finished
```

Typical uses:

* total
* average
* maximum
* minimum
* final report
* counters

---

# 9. BEGIN + main block + END

This is one of the most important AWK patterns.

```bash
awk '
BEGIN {
    print "START"
}
{
    print $2
}
END {
    print "END"
}
' data.txt
```

Execution:

```text
BEGIN
  ↓
Process every line
  ↓
END
```

Think of it as:

```text
┌───────────────┐
│     BEGIN     │
│ initialization│
└───────┬───────┘
        ↓
┌───────────────┐
│   Each line   │
│  processing   │
└───────┬───────┘
        ↓
┌───────────────┐
│      END      │
│ final result  │
└───────────────┘
```

---

# 10. Accumulator

This is **very important for AWK coding questions**.

An accumulator is simply a variable that keeps adding values.

Suppose:

```text
Alice 50000
Bob   60000
John  55000
Ravi  70000
```

We want total salary.

```bash
awk '{sum += $2} END {print sum}' data.txt
```

Output:

```text
235000
```

This:

```awk
sum += $2
```

is equivalent to:

```awk
sum = sum + $2
```

AWK automatically initializes `sum` to `0`.

---

# 11. Accumulator step by step

Input:

```text
Alice 50000
Bob   60000
John  55000
Ravi  70000
```

AWK internally does:

```text
Initially:
sum = 0

Alice:
sum = 0 + 50000
    = 50000

Bob:
sum = 50000 + 60000
    = 110000

John:
sum = 110000 + 55000
    = 165000

Ravi:
sum = 165000 + 70000
    = 235000
```

Then:

```awk
END {print sum}
```

prints:

```text
235000
```

---

# 12. Counter

Accumulator isn't always addition of a column.

You can also count things.

Suppose:

```text
Alice Linux
Bob   Linux
John  Docker
Ravi  Linux
```

Count Linux users:

```bash
awk '$2 == "Linux" {count++} END {print count}' data.txt
```

Output:

```text
3
```

Here:

```awk
count++
```

means:

```awk
count = count + 1
```

So:

```text
count = 0
Alice → Linux → count = 1
Bob   → Linux → count = 2
John  → Docker
Ravi  → Linux → count = 3
```

---

# 13. `FS` — Field Separator

By default AWK considers whitespace as the separator.

For:

```text
Alice 50000
Bob 60000
```

AWK understands:

```text
Alice | 50000
```

But suppose CSV:

```text
Alice,50000,India
Bob,60000,India
```

You need:

```bash
awk -F',' '{print $1, $2}' data.csv
```

`-F','` means:

```text
FS = ,
```

You can also use:

```bash
awk 'BEGIN {FS=","} {print $1, $2}' data.csv
```

Both are valid.

---

# 14. `OFS` — Output Field Separator

Suppose:

```bash
awk '{print $1, $2}' data.txt
```

AWK normally separates output fields using a space.

You can change it:

```bash
awk 'BEGIN {OFS=","} {print $1, $2}' data.txt
```

Output:

```text
Alice,50000
Bob,60000
John,55000
Ravi,70000
```

Remember:

```text
FS  → Input separator
OFS → Output separator
```

Very important.

---

# 15. `RS` — Record Separator

Normally AWK considers:

```text
one line = one record
```

because:

```text
RS = newline
```

You can change it.

For example:

```text
Alice|50000|India
Bob|60000|India
```

You could use:

```bash
awk 'BEGIN {RS="|"} {print $0}' file
```

Now each `|` separates records.

You don't need to use `RS` frequently for beginner questions, but know what it means.

---

# 16. `ORS` — Output Record Separator

Default:

```text
ORS = newline
```

Example:

```bash
awk 'BEGIN {ORS=" "} {print $1}' data.txt
```

Instead of:

```text
Alice
Bob
John
Ravi
```

you get:

```text
Alice Bob John Ravi
```

Remember:

```text
RS  → input record separator
ORS → output record separator
```

---

# 17. `NR` + condition

Very common.

### Print first 2 lines

```bash
awk 'NR <= 2 {print}' data.txt
```

### Print line 3

```bash
awk 'NR == 3 {print}' data.txt
```

### Skip first line

```bash
awk 'NR > 1 {print}' data.txt
```

This is extremely useful for skipping CSV headers.

---

# 18. `NF` + condition

Print lines having exactly 3 columns:

```bash
awk 'NF == 3 {print}' data.txt
```

Print lines having more than 3 columns:

```bash
awk 'NF > 3 {print}' data.txt
```

Print lines having fewer than 3 columns:

```bash
awk 'NF < 3 {print}' data.txt
```

---

# 19. `NR`, `NF`, `$NF` together

Suppose:

```text
Alice Linux 50000
Bob Docker 60000
John Kubernetes 70000
```

Run:

```bash
awk '{print "Line:", NR, "Columns:", NF, "Last:", $NF}' data.txt
```

Output:

```text
Line: 1 Columns: 3 Last: 50000
Line: 2 Columns: 3 Last: 60000
Line: 3 Columns: 3 Last: 70000
```

This is a great example to understand the variables.

---

# 20. `ARGC` and `ARGV`

AWK also has command-line argument variables.

Example:

```bash
awk 'BEGIN {print ARGC; print ARGV[0]; print ARGV[1]}' data.txt
```

These are less important for beginner/interview coding questions, but you may encounter them.

```text
ARGC → number of command-line arguments
ARGV → array containing arguments
```

---

# 21. `length()`

Find length of a string:

```bash
awk '{print $2, length($2)}' data.txt
```

Example:

```text
Alice 5
Bob 3
John 4
Ravi 4
```

Useful for string-based questions.

---

# 22. `substr()`

Extract part of a string.

```bash
awk '{print substr($2,1,3)}' data.txt
```

For:

```text
Alice
Bob
John
Ravi
```

Output:

```text
Ali
Bob
Joh
Rav
```

Syntax:

```text
substr(string, starting_position, length)
```

---

# 23. `split()`

Very useful for advanced AWK.

Suppose:

```text
Alice:Linux:Docker
```

You can split it:

```bash
awk '{
    n = split($0, arr, ":")
    print arr[1], arr[2], arr[3]
}' file
```

Output:

```text
Alice Linux Docker
```

`split()` creates an array.

---

# 24. Associative arrays

This is **one of the most important AWK concepts**.

Suppose:

```text
Linux 100
Docker 200
Linux 300
Docker 100
Linux 200
```

We want:

```text
Linux 600
Docker 300
```

Use:

```bash
awk '{sum[$1] += $2} END {for (key in sum) print key, sum[key]}' file
```

This is extremely important.

AWK creates an associative array:

```text
sum["Linux"]  = 600
sum["Docker"] = 300
```

This pattern solves many:

* grouping
* counting
* aggregation
* duplicate removal
* totals by key

questions.

---

# 25. Your earlier CSV example

Suppose:

```text
A,100
B,200
A,300
C,500
B,100
A,50
```

Requirement:

> Distinct keys and total values.

Use:

```bash
awk -F',' '{sum[$1] += $2} END {for (key in sum) print key, sum[key]}' file.csv
```

Output could be:

```text
A 450
B 300
C 500
```

The core idea is:

```awk
sum[$1] += $2
```

This is:

```text
key       accumulator
 ↓             ↓
sum[$1]  +=    $2
```

---

# 26. `delete`

You can delete an array element:

```awk
delete sum["Linux"]
```

Useful when manipulating associative arrays.

---

# 27. `next`

`next` means:

> Stop processing the current line and immediately move to the next line.

Example:

```bash
awk 'NR == 1 {next} {print $0}' data.txt
```

This skips the first line.

Another common example:

```bash
awk '$2 == "ERROR" {next} {print}' logfile
```

Meaning:

```text
If ERROR → skip line
Otherwise → print
```

---

# 28. `exit`

`exit` completely stops AWK.

Example:

```bash
awk 'NR == 3 {exit} {print}' data.txt
```

Output:

```text
first line
second line
```

Once `NR == 3`, AWK exits.

---

# 29. `if / else`

AWK supports conditions.

```bash
awk '{
    if ($3 >= 60000)
        print $2, "High Salary"
    else
        print $2, "Low Salary"
}' data.txt
```

---

# 30. `for` loop

Very important for arrays.

```bash
awk '
{
    sum[$1] += $2
}
END {
    for (key in sum)
        print key, sum[key]
}
' file
```

The important syntax is:

```awk
for (key in array)
```

---

# 31. `match()` and regex

AWK is very powerful for pattern matching.

Example:

```bash
awk '$2 ~ /Linux/ {print}' file
```

Means:

```text
If column 2 matches "Linux"
```

Negation:

```bash
awk '$2 !~ /Linux/ {print}' file
```

---

# 32. The most important AWK symbols

You should memorize these:

| Term          | Meaning                     |
| ------------- | --------------------------- |
| `$0`          | Entire line                 |
| `$1`, `$2`... | Fields                      |
| `NF`          | Number of fields            |
| `$NF`         | Last field                  |
| `NR`          | Overall record/line number  |
| `FNR`         | Record/line number per file |
| `FS`          | Input field separator       |
| `OFS`         | Output field separator      |
| `RS`          | Input record separator      |
| `ORS`         | Output record separator     |
| `BEGIN`       | Before reading input        |
| `END`         | After reading input         |
| `next`        | Skip current line           |
| `exit`        | Stop AWK                    |
| `ARGC`        | Number of arguments         |
| `ARGV`        | Argument array              |

---

# 33. The patterns you REALLY need for interviews

Instead of trying to memorize everything, master these **10 patterns**.

### Pattern 1 — Print a column

```bash
awk '{print $2}' file
```

### Pattern 2 — Print line number

```bash
awk '{print NR, $0}' file
```

### Pattern 3 — Print last column

```bash
awk '{print $NF}' file
```

### Pattern 4 — Skip header

```bash
awk 'NR > 1 {print}' file
```

### Pattern 5 — Filter

```bash
awk '$3 > 50000 {print}' file
```

### Pattern 6 — Sum

```bash
awk '{sum += $3} END {print sum}' file
```

### Pattern 7 — Count

```bash
awk '{count++} END {print count}' file
```

### Pattern 8 — Group + sum

```bash
awk '{sum[$1] += $2} END {for (k in sum) print k, sum[k]}' file
```

### Pattern 9 — Group + count

```bash
awk '{count[$1]++} END {for (k in count) print k, count[k]}' file
```

### Pattern 10 — Average

```bash
awk '{sum += $3; count++} END {print sum/count}' file
```

---

# 34. The BIG AWK mental model

If you remember only one thing, remember this:

```text
                 AWK
                  │
        ┌─────────┴─────────┐
        ↓                   ↓
      BEGIN               END
   initialization       final result
        │                   ↑
        └───────┐   ┌───────┘
                ↓   ↑
          Every input line
                │
       ┌────────┼────────┐
       ↓        ↓        ↓
      $1       NF       NR
    field    columns   line no.
       │
       ↓
   Conditions
       │
       ↓
   Variables
       │
       ├── sum += value
       ├── count++
       ├── max = ...
       └── array[key] += value
```

The **most important progression for your AWK hands-on practice** is:

```text
$0 / $1 / $NF
       ↓
NR / NF / FNR
       ↓
BEGIN / END
       ↓
FS / OFS
       ↓
if / else
       ↓
sum / count / accumulator
       ↓
arrays
       ↓
for (key in array)
       ↓
next / exit
       ↓
regex
       ↓
split / substr / match
```

If you master these, you can solve a **large majority of practical AWK interview questions**.
