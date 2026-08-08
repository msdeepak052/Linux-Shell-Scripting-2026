# Cloud CLI Scripting: `aws`, `gcloud`, `az` from Bash

Cloud automation in practice is bash gluing together CLI calls, not SDKs — knowing how to parse, filter, and safely wrap `aws`/`gcloud`/`az` output is a daily senior-platform-engineer skill.

## Explanation

**`aws` CLI**: supports native server-side filtering via `--query` (JMESPath syntax) and `--filters`, plus `--output json|text|table`. `--query` reduces payload before it even reaches `jq`, which matters for large accounts.
- `--query` uses JMESPath: `'Reservations[].Instances[].InstanceId'`, `[?State.Name=='running']` for filtering.
- `--output text` + `--query` is a fast way to get plain values without `jq` at all, for simple cases.
- `aws ... --query ... --output json | jq ...` is the standard combo when JMESPath alone can't express the transform you need (jq's language is more powerful for complex reshaping).
- `--profile` / `AWS_PROFILE` and `--region` / `AWS_DEFAULT_REGION` — always pin explicitly in scripts, never rely on ambient defaults in shared automation.
- `aws sts get-caller-identity` — the standard "am I authenticated as who I think I am" sanity check to run at the top of any AWS automation script.

**`gcloud` CLI**: supports `--format` with its own format language (`json`, `yaml`, `value(field)`, `csv[no-heading]`, and a jq-like path syntax `'value(name,status)'`).
- `--format='value(field)'` — extract a single field, no post-processing needed for simple cases.
- `--format=json | jq ...` — for anything more complex.
- `gcloud config configurations list` / `gcloud config set project X` — explicit project selection matters, `gcloud`'s ambient project context is a common source of "ran against the wrong project" incidents.
- `--filter` — server-side filtering, e.g. `--filter="status=RUNNING"`.

**`az` CLI**: uses `--query` with JMESPath too (same language as AWS), plus `--output json|table|tsv`.
- `az account show` — equivalent sanity check to `aws sts get-caller-identity`.
- `az ... --query '[].{Name:name, State:powerState}' --output table` — JMESPath projection directly into a readable table, no jq needed for simple reporting.

**Cross-cutting production concerns**:
- **Pagination**: all three CLIs paginate large result sets by default in some contexts (`aws` uses `NextToken`, auto-paginates by default unless `--no-paginate`; `gcloud` and `az` mostly auto-paginate). Verify you're getting the full result set, not just page 1, especially when scripting against accounts with many resources.
- **Throttling/rate limits**: wrap cloud CLI calls in retry logic with backoff — these APIs rate-limit aggressively under bulk scripting.
- **Idempotency**: cloud CLI wrapper scripts that create resources should check-then-act or handle "already exists" errors gracefully — reruns are common (CI retries, on-call re-triggering).
- **Credentials never in scripts**: rely on instance profiles/workload identity/`az login --identity`, or externally-injected env vars — never hardcode keys in the script itself.

## Hands-On Examples

**1. AWS: `--query` (JMESPath) vs `jq` for the same extraction**
```bash
# Native JMESPath, no jq needed
$ aws ec2 describe-instances \
    --query "Reservations[].Instances[?State.Name=='running'].InstanceId[]" \
    --output text
i-0a1b2c3d4e5f6a7b8	i-0f9e8d7c6b5a4938

# Same result via jq (useful when the transform is too complex for JMESPath)
$ aws ec2 describe-instances --output json \
    | jq -r '.Reservations[].Instances[] | select(.State.Name=="running") | .InstanceId'
i-0a1b2c3d4e5f6a7b8
i-0f9e8d7c6b5a4938
```

**2. AWS: sanity-checking identity before running destructive automation**
```bash
$ cat > guard.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
account_id=$(aws sts get-caller-identity --query Account --output text)
expected="123456789012"
if [[ "$account_id" != "$expected" ]]; then
    echo "ERROR: running against account $account_id, expected $expected. Aborting." >&2
    exit 1
fi
echo "Account verified: $account_id"
EOF
$ ./guard.sh
Account verified: 123456789012
```

**3. gcloud: `--format=value()` for quick scripting extraction**
```bash
$ gcloud compute instances list --filter="status=RUNNING" --format="value(name,zone)"
web-01	us-central1-a
web-02	us-central1-b

$ instance_names=$(gcloud compute instances list --filter="status=RUNNING" --format="value(name)")
$ for name in $instance_names; do
    echo "Restarting $name"
    gcloud compute instances reset "$name" --zone=us-central1-a --quiet
  done
```

**4. gcloud: JSON + jq for a more complex report**
```bash
$ gcloud compute instances list --format=json \
    | jq -r '.[] | select(.status=="RUNNING") | [.name, .machineType | split("/") | last] | @tsv'
web-01	e2-medium
web-02	e2-standard-4
```

**5. az: JMESPath `--query` projection straight into a table**
```bash
$ az vm list -d --query "[?powerState=='VM running'].{Name:name, RG:resourceGroup, Size:hardwareProfile.vmSize}" \
    --output table
Name      RG              Size
--------  --------------  -----------
web-01    prod-rg         Standard_D2s_v3
web-02    prod-rg         Standard_D4s_v3
```

**6. az: identity check + subscription pinning at script start**
```bash
$ cat > az-guard.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
az account set --subscription "prod-subscription-id"
current=$(az account show --query name -o tsv)
echo "Operating in subscription: $current"
EOF
```

**7. Wrapping a cloud CLI call with retry/backoff for throttling**
```bash
$ cat > retry_aws.sh << 'EOF'
#!/usr/bin/env bash
retry() {
    local max=5 delay=2 attempt=1
    until "$@"; do
        if (( attempt >= max )); then
            echo "Command failed after $max attempts: $*" >&2
            return 1
        fi
        echo "Attempt $attempt failed, retrying in ${delay}s..." >&2
        sleep "$delay"
        ((attempt++))
        delay=$((delay * 2))
    done
}
retry aws s3 cp report.csv s3://prod-reports-bucket/report.csv
EOF
```

**8. Cross-account/cross-project audit: same pattern, three clouds**
```bash
$ echo "== AWS EC2 running instances =="
$ aws ec2 describe-instances --query 'Reservations[].Instances[?State.Name==`running`].InstanceId[]' --output text

$ echo "== GCP running instances =="
$ gcloud compute instances list --filter="status=RUNNING" --format="value(name)"

$ echo "== Azure running VMs =="
$ az vm list -d --query "[?powerState=='VM running'].name" -o tsv
```

## Practice Questions

1. Compare `aws ec2 describe-instances --query ... --output text` versus piping JSON output into `jq`. When would you prefer JMESPath's `--query` over `jq`, and when does `jq` win?
2. Write an `aws sts get-caller-identity` guard clause that aborts a script if the running account doesn't match an expected account ID — why is this important for destructive automation (e.g., terminate/delete scripts)?
3. What's the risk of a `gcloud` script relying on the ambient `gcloud config` project context instead of explicitly passing `--project`? Describe a real incident this could cause.
4. Explain `az`'s `--query` JMESPath syntax and write a query that returns VM name + power state + resource group as a table for all VMs in a subscription.
5. Why should cloud CLI wrapper scripts implement retry-with-backoff, and what HTTP/API behavior are you defending against?
6. A script using `aws ec2 describe-instances` only returns the first 1000 results in an account with 3000 instances. What's happening, and how do you fix it (mention `--no-paginate`/pagination tokens)?
7. Why is hardcoding AWS access keys or a service account JSON key inside a wrapper script considered a serious anti-pattern? What should be used instead in EC2/GKE/Azure VM contexts?
8. Write a bash function `retry()` that wraps any command and retries it up to N times with exponential backoff — explain why this matters specifically for cloud CLI calls versus purely local commands.
9. Given `az vm list -d --query "[?powerState=='VM running'].{Name:name}" -o tsv`, what does the `-d` flag do, and why would omitting it silently produce wrong/incomplete data for this particular query?
10. Design a script that checks resource state is idempotent — e.g., "create this S3 bucket if it doesn't already exist" — without failing on rerun. What AWS CLI pattern (checking first vs catching the "already exists" error) would you use, and why?

## Interview Key Points

- Know JMESPath (`--query` in both `aws` and `az`) versus `jq` — JMESPath is native/fast for simple filters, `jq` wins for complex reshaping; being able to write both live is a strong signal.
- Always mention an identity/account sanity check (`aws sts get-caller-identity`, `az account show`, `gcloud config get-value project`) as the first line of any consequential cloud automation script — this is a classic "how do you prevent running against the wrong account" answer.
- Pagination is a real, frequently-tested gotcha — interviewers probe whether you know cloud CLIs can silently truncate large result sets without explicit pagination handling.
- Rate limiting/throttling handling (retry + exponential backoff) separates "script that works in a demo" from "script that survives production scale" — always mention it when asked about robustness.
- Never hardcode credentials in scripts — instance profiles / workload identity federation / managed identities are the expected answer, and interviewers listen for this explicitly.
- `--output text`/`value()`/`-o tsv` for simple single-value extraction (no jq needed) versus `--output json | jq` for complex logic — knowing when NOT to reach for jq is itself a signal of practical experience.
- Idempotency in create/delete wrapper scripts (check-then-act, or catch "already exists"/"not found" as non-fatal) is expected in any script that will be rerun by CI or on-call responders.
