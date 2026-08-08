# Arrays: Indexed & Associative

Bash isn't just scalars — arrays let you hold lists and key-value maps natively, no external tools needed.

## Explanation

**Indexed arrays** (bash 3+): ordered list, integer-indexed from 0, indices don't need to be contiguous.
```bash
arr=(web01 web02 db01)          # declare + initialize
arr[3]="cache01"                # append/set by index
declare -a arr                  # explicit declaration (optional)
```

**Associative arrays** (bash 4+ only — not in macOS's ancient default bash 3.2): key-value maps, must be explicitly declared.
```bash
declare -A config
config[env]="production"
config[region]="us-east-1"
```

**Common operations**:
| Operation | Syntax |
|---|---|
| Access element | `${arr[0]}`, `${config[env]}` |
| All elements | `${arr[@]}` (separate words) or `${arr[*]}` (one string) |
| All keys (assoc) | `${!config[@]}` |
| Length | `${#arr[@]}` |
| Slice | `${arr[@]:1:2}` (start:count) |
| Append | `arr+=(new_item)` |
| Delete element | `unset 'arr[1]'` |
| Iterate | `for x in "${arr[@]}"; do ... done` |

Just like `"$@"`, always quote `"${arr[@]}"` when iterating — unquoted expansion word-splits each element, breaking on internal spaces.

## Hands-On Examples

**1. Indexed array basics**
```bash
$ servers=(web01 web02 db01 cache01)
$ echo "${servers[0]}"
web01
$ echo "${servers[@]}"
web01 web02 db01 cache01
$ echo "Total servers: ${#servers[@]}"
Total servers: 4

$ servers+=(worker01)
$ echo "${servers[@]}"
web01 web02 db01 cache01 worker01
```

**2. Iterating safely (quoted expansion)**
```bash
$ paths=("/var/log/app one.log" "/var/log/app-two.log")
$ for p in ${paths[@]}; do echo "[$p]"; done      # UNQUOTED — breaks on internal space
[/var/log/app]
[one.log]
[/var/log/app-two.log]

$ for p in "${paths[@]}"; do echo "[$p]"; done    # QUOTED — correct
[/var/log/app one.log]
[/var/log/app-two.log]
```

**3. Associative arrays — a config map**
```bash
$ declare -A config
$ config[env]="production"
$ config[region]="us-east-1"
$ config[instance_type]="m5.large"

$ echo "Env: ${config[env]}, Region: ${config[region]}"
Env: production, Region: us-east-1

$ for key in "${!config[@]}"; do
>     echo "$key => ${config[$key]}"
> done
env => production
region => us-east-1
instance_type => m5.large
```

**4. Real-world: building an array from command output**
```bash
$ mapfile -t running_pods < <(kubectl get pods --no-headers -o custom-columns=":metadata.name")
$ echo "Found ${#running_pods[@]} pods"
Found 3 pods
$ for pod in "${running_pods[@]}"; do
>     echo "Checking logs for $pod..."
> done
Checking logs for api-7d9f8-x2j4k...
Checking logs for worker-5b6c7-p9m2n...
Checking logs for cache-3a1b2-q7r8s...
```

**5. Associative array as a lookup table — dispatch pattern**
```bash
$ declare -A env_ports=(
>     [dev]=3000
>     [staging]=4000
>     [prod]=8080
> )
$ env="staging"
$ echo "Port for $env: ${env_ports[$env]}"
Port for staging: 4000

$ if [[ -v env_ports[$env] ]]; then    # -v checks key existence
>     echo "Valid environment"
> else
>     echo "Unknown environment: $env"
> fi
Valid environment
```

**6. Slicing and deleting elements**
```bash
$ hosts=(h1 h2 h3 h4 h5)
$ echo "${hosts[@]:1:3}"      # start at index 1, take 3 elements
h2 h3 h4

$ unset 'hosts[2]'
$ echo "${hosts[@]}"           # h3 is gone, but indices are now non-contiguous (0,1,3,4)
h1 h2 h4 h5

$ echo "${!hosts[@]}"          # show actual indices remaining
0 1 3 4
```

**7. Real-world: parsing `/etc/passwd` lines into a structured array-of-fields loop**
```bash
$ while IFS=':' read -ra fields; do
>     [[ "${fields[2]}" -ge 1000 ]] && echo "User: ${fields[0]}, Home: ${fields[5]}"
> done < /etc/passwd
User: deepak, Home: /home/deepak
User: svc_deploy, Home: /home/svc_deploy
```

## Practice Questions

1. What's the difference between `declare -a` and `declare -A` in bash, and what's the minimum bash version required for associative arrays?
2. Write a script that builds an indexed array from the output of `kubectl get pods --no-headers -o custom-columns=":metadata.name"` and prints how many pods were found.
3. Why does `for x in ${arr[@]}; do ... done` (unquoted) potentially break when array elements contain spaces, and how do you fix it?
4. Write an associative array mapping environment names (`dev`, `staging`, `prod`) to port numbers, then look up and print the port for a given environment variable.
5. What's the output of `unset 'arr[1]'` on an array `arr=(a b c d)` — does the array re-index afterward, or leave a gap? How would you verify this with `${!arr[@]}`?
6. Write a snippet using `mapfile` (or `readarray`) to load every line of `/etc/hosts` into an array, then print only lines NOT starting with `#`.
7. How do you check whether a specific key exists in an associative array WITHOUT triggering "unbound variable" issues under `set -u`? (Hint: `-v`)
8. What does `${arr[@]:2:3}` do? Give a concrete example with a 6-element array and show the expected output.
9. Explain the difference between `${arr[@]}` and `${arr[*]}` when the array is expanded inside double quotes and assigned to a new variable.
10. Write a function that takes a list of server names as arguments (`$@`), stores them in a local array, and prints them numbered (1. web01, 2. web02, ...).

## Interview Key Points

- **Associative arrays require `declare -A`** and bash 4+ — a common gotcha on macOS where the *system* bash is still 3.2 (Apple ships an old GPLv2 version); mentioning this shows real-world awareness.
- Always quote array expansions in loops: `"${arr[@]}"` not `${arr[@]}` — same word-splitting principle as `"$@"` vs `$@`.
- `${#arr[@]}` = element count; `${!arr[@]}` = list of indices/keys — these two are frequently confused, know them cold.
- `unset` on an array element leaves a **gap** in indexed arrays (doesn't re-index) — a real gotcha when code assumes contiguous indices after deletion.
- `mapfile -t` (a.k.a. `readarray -t`) is the modern, efficient way to load command output or file lines directly into an array — the `-t` strips trailing newlines, know to always include it.
- `[[ -v arr[key] ]]` checks key existence in an associative array without errors — useful under `set -u` (nounset) where referencing a missing key otherwise triggers "unbound variable."
- Associative arrays as **lookup/dispatch tables** (env → port, region → AMI ID, etc.) is a very common real-world platform-engineering pattern to demonstrate in an interview.
