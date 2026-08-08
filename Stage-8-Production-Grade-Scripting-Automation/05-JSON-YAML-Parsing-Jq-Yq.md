# JSON/YAML Parsing in Shell (`jq`, `yq`)

Modern infrastructure tooling speaks JSON and YAML almost exclusively — `jq` and `yq` are what let bash scripts consume that output reliably instead of fragile `grep`/`awk` scraping.

## Explanation

**`jq`** — a JSON processor with its own filter language. Core mental model: data flows through a pipeline of filters, like a shell pipe but operating on JSON structure instead of text.

- `.` — identity (print input as-is)
- `.field` / `.a.b.c` — object field access (nested)
- `.[]` — iterate array/object elements
- `.[0]`, `.[2:5]` — index/slice
- `select(cond)` — filter elements matching a boolean expression
- `map(expr)` — apply expr to every element of an array
- `-r` — raw output (strip surrounding quotes from strings, essential for shell consumption)
- `-c` — compact single-line output (good for piping to `wc -l`, or one-JSON-object-per-line)
- `-e` — exit non-zero if output is `null`/`false` (useful in `set -e` scripts to detect "not found")
- `@csv`, `@tsv`, `@base64` — output format converters
- `//` — alternative operator, like bash's `${var:-default}`: `.field // "default"`
- `to_entries` / `from_entries` — convert object <-> array of `{key,value}`, useful for iterating maps
- `jq -n` — no input, build JSON from scratch (useful for constructing payloads)

**`yq`** — YAML equivalent, syntax is jq-compatible in the popular Mike Farah (`mikefarah/yq`, Go binary) version, which is what most teams mean by "yq" today. (The older Python `yq` wraps `jq` and requires `.` prefix differently — always check `yq --version` on a new box.) `yq` can also convert YAML<->JSON<->XML, which makes it the standard bridge for feeding Kubernetes manifests or Ansible vars into `jq` pipelines.

**Common gotchas**:
- `jq` output is quoted JSON strings by default (`"i-0123abc"`) — forgetting `-r` means your bash variable literally contains the quote characters.
- `jq` errors loudly (non-zero exit, stderr message) on invalid/empty input — wrap external command output that might legitimately be empty.
- Missing keys return `null`, not an error — chain `// empty` or `// "default"` to handle absence.
- `yq` v3 vs v4 (mikefarah) have different CLI syntax (`yq r file.yaml a.b` vs `yq '.a.b' file.yaml`) — version drift across machines is a real-world pain point, always pin/check.
- Piping `jq` output directly into a bash array requires `mapfile`/`readarray` or `while read`, not naive `$(...)` word-splitting, to survive spaces in values.

## Hands-On Examples

**1. Basic field extraction with `-r`**
```bash
$ echo '{"name":"web-01","status":"running","port":8080}' | jq -r '.name'
web-01

$ echo '{"name":"web-01"}' | jq '.name'      # without -r: quotes included
"web-01"
```

**2. Extracting instance IDs from `aws ec2 describe-instances`**
```bash
$ aws ec2 describe-instances --filters "Name=tag:Env,Values=prod" \
    | jq -r '.Reservations[].Instances[] | select(.State.Name=="running") | .InstanceId'
i-0a1b2c3d4e5f6a7b8
i-0f9e8d7c6b5a4938

# Same, but as a comma-separated list for reuse in another AWS call
$ ids=$(aws ec2 describe-instances --filters "Name=tag:Env,Values=prod" \
    | jq -r '[.Reservations[].Instances[].InstanceId] | join(",")')
$ echo "$ids"
i-0a1b2c3d4e5f6a7b8,i-0f9e8d7c6b5a4938
```

**3. Building a table with `-r` + `@tsv` (feeds nicely into `column -t`)**
```bash
$ aws ec2 describe-instances \
    | jq -r '.Reservations[].Instances[] | [.InstanceId, .InstanceType, .State.Name] | @tsv' \
    | column -t
i-0a1b2c3d4e5f6a7b8  t3.medium  running
i-0f9e8d7c6b5a4938   t3.large   stopped
```

**4. Safe handling of missing fields with `//`**
```bash
$ echo '{"name":"svc-a"}' | jq -r '.owner // "unassigned"'
unassigned

$ echo '{"name":"svc-a","owner":"platform-team"}' | jq -r '.owner // "unassigned"'
platform-team
```

**5. Reading a Kubernetes-style YAML with `yq` (mikefarah v4 syntax)**
```bash
$ cat deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: app
          image: registry.internal/payments-api:1.4.2

$ yq '.spec.replicas' deployment.yaml
3
$ yq '.spec.template.spec.containers[0].image' deployment.yaml
registry.internal/payments-api:1.4.2

# Bump the image tag in-place
$ yq -i '.spec.template.spec.containers[0].image = "registry.internal/payments-api:1.4.3"' deployment.yaml
```

**6. Converting YAML to JSON to hand off to `jq` (or vice versa)**
```bash
$ yq -o=json '.' values.yaml > values.json
$ cat values.json | jq '.replicaCount'
3

# Piping directly, no temp file
$ yq -o=json '.' values.yaml | jq -r '.image.repository + ":" + .image.tag'
myorg/payments-api:1.4.2
```

**7. Iterating a JSON array in bash safely (spaces-in-values safe)**
```bash
$ aws s3api list-buckets | jq -r '.Buckets[].Name' > /tmp/buckets.txt
$ while IFS= read -r bucket; do
    echo "Checking bucket: $bucket"
    aws s3api get-bucket-encryption --bucket "$bucket" >/dev/null 2>&1 \
      && echo "  encrypted" || echo "  NOT ENCRYPTED"
  done < /tmp/buckets.txt
Checking bucket: prod-app-logs
  encrypted
Checking bucket: legacy-uploads-2019
  NOT ENCRYPTED
```

**8. Building JSON from scratch with `jq -n` (e.g., a Slack webhook payload)**
```bash
$ status="failed"
$ env="production"
$ payload=$(jq -n --arg status "$status" --arg env "$env" \
    '{text: "Deploy \($status) in \($env)", channel: "#platform-alerts"}')
$ echo "$payload"
{"text":"Deploy failed in production","channel":"#platform-alerts"}
$ curl -sf -X POST -H 'Content-Type: application/json' -d "$payload" "$SLACK_WEBHOOK_URL"
```

## Practice Questions

1. Why is `-r` critical when piping `jq` output into a bash variable that will be used as a CLI argument later? What breaks if you forget it?
2. Given `aws ec2 describe-instances` JSON output, write a `jq` filter that extracts only `InstanceId` for instances tagged `Name=web-*` and in `running` state.
3. What's the difference between `.field` returning `null` versus `jq` erroring out, and how do you distinguish "key absent" from "key present with null value"?
4. Explain the `//` alternative operator in `jq` with an example, and compare it to bash's `${var:-default}`.
5. You need to convert a Helm `values.yaml` into JSON to feed into a `jq` pipeline. Write the command, and explain why `yq -o=json` is preferable to a hand-rolled YAML parser in bash.
6. Why does naively doing `for id in $(jq -r '.[].id' file.json)` break on values containing spaces, and what's the safe alternative?
7. Write a `jq` filter using `map(select(...))` that filters a JSON array of objects `[{"name":"a","cpu":80},{"name":"b","cpu":40}]` down to only entries with `cpu > 50`.
8. What's the practical difference between `yq` v3 (Python-wrapper) and v4 (Go, mikefarah) syntax, and why does this matter when scripts run across heterogeneous machines/CI images?
9. Using `jq -n`, construct a JSON payload from three bash variables (`$service`, `$version`, `$status`) suitable for POSTing to a webhook — explain why `--arg` is safer than string-interpolating the variables directly into the filter.
10. You run `some_api_call | jq '.result'` and get `jq: error (at <stdin>:0): Cannot index string with "result"`. What does this tell you about the upstream command's actual output, and how would you debug it?

## Real Interview Questions (Company-Attributed)

- "Explain the use of `jq` and `yq`." — asked at *Sigmoid* (part of a rapid-fire "explain these Linux commands" interview round)

## Interview Key Points

- `-r` (raw output) is the single most-forgotten flag — without it, JSON string quotes leak into shell variables and break comparisons/paths. Interviewers love asking "what's wrong with this snippet" when `-r` is missing.
- `select()` + `map()` is the jq equivalent of `WHERE` + a projection — know this pairing cold, it covers 80% of real filtering needs (e.g., "give me running instances only").
- `//` (alternative operator) is how you handle optional/missing JSON fields gracefully — equivalent mental model to bash's `${var:-default}`.
- `jq -n --arg` is the safe way to build JSON payloads from shell variables — avoids injection/escaping bugs you'd get from string-concatenating JSON by hand.
- Know that `mikefarah/yq` (Go binary, jq-like syntax, supports `-i` in-place edit and YAML<->JSON conversion) is the modern standard — version mismatches across machines are a real, commonly-tested gotcha.
- `yq -o=json file.yaml | jq ...` is the standard bridge pattern for treating YAML (Helm values, K8s manifests, Ansible vars) with jq's more mature filter language.
- Always assume upstream JSON might be empty, malformed, or `null` — production scripts wrap `jq` calls with exit-code checks or `// empty` rather than trusting well-formed input blindly.
