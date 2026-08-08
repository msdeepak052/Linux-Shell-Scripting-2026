# Shell's Role in IaC & Deployment Pipelines

Shell is glue, not a platform — knowing precisely where it belongs versus where Terraform/Ansible/a real language should take over is a senior-level signal.

## Explanation

**What shell is genuinely good for in a pipeline:**
- Orchestration/sequencing: calling `terraform`, `ansible-playbook`, `kubectl`, `aws`/`gcloud`/`az` CLIs in the right order with the right flags.
- Environment prep: exporting env vars, sourcing secrets, templating small config fragments, setting up temp workspaces.
- Thin wrappers/CI entrypoints: the single script a CI job or Makefile target calls, which then delegates to real tools.
- Quick pre-flight/post-flight checks: "is kubectl context correct?", "did terraform plan produce changes?", "did the health endpoint come back 200 after rollout?".
- Parsing CLI tool output (with `jq`/`yq`) to make a go/no-go decision or feed a value into the next command.

**Where shell is the wrong tool (and why):**
- **State management** — shell has no concept of desired-state reconciliation, diffing, or drift detection. That's Terraform/Pulumi/CloudFormation's entire job; reimplementing it in bash (e.g., "check if resource exists, if not create it") is a fragile, non-idempotent trap.
- **Complex conditional/branching business logic** — once you're nesting more than ~2 levels of `if`/loops with real data structures, you're fighting bash's weak typing and array handling. Move to Python/Go.
- **Anything needing real error recovery** — retries with backoff, partial-failure rollback, structured error types are painful and bug-prone in shell; libraries in Python/Go make this trivial.
- **Cross-platform portability** — bash on the CI runner may not match bash on an engineer's Mac (BSD vs GNU `sed`/`date`/`grep` differences) or a minimal container's `sh` (dash, no arrays, no `[[`).
- **Secrets handling logic** — shell leaks secrets easily (env vars visible in `/proc/<pid>/environ`, appearing in `set -x` trace output, in shell history, in `ps aux` for inline args). Fine to *pass through* env vars set by a vault integration; risky to *construct or manipulate* secrets in shell logic.
- **Anything that needs unit tests to be trustworthy at scale** — shell is testable (bats/shunit2), but a 500-line bash deployment script with branching logic is a maintenance and reliability risk versus the same logic in a typed language with a real test suite.

**The mental model senior engineers use:** shell is the **connective tissue** between purpose-built tools, not a replacement for them. Terraform manages infra state. Ansible manages config/idempotent changes to existing hosts. kubectl/Helm manage k8s manifests. Cloud CLIs manage cloud API calls. Shell's job is to invoke these in sequence, pass outputs between them, and make simple pass/fail decisions — nothing more.

**Common pipeline shape:**
```
CI trigger → wrapper script (bash)
                 ├─ terraform init/plan/apply   (infra provisioning)
                 ├─ parse terraform output (jq) → feed into next step
                 ├─ ansible-playbook            (config management / app deploy)
                 ├─ kubectl apply / helm upgrade (k8s workload deploy)
                 └─ post-deploy smoke test (curl + shell exit-code check)
```
The wrapper script itself should stay thin: sequencing, exit-code checking, logging — not business logic.

## Hands-On Examples

**1. A well-scoped deployment wrapper — shell doing what it should**
```bash
#!/usr/bin/env bash
set -euo pipefail

ENV="${1:?Usage: deploy.sh <env>}"

echo "==> Planning infra changes for $ENV"
terraform -chdir="envs/$ENV" plan -out=tfplan

echo "==> Applying infra changes"
terraform -chdir="envs/$ENV" apply -auto-approve tfplan

echo "==> Extracting outputs for Ansible inventory"
terraform -chdir="envs/$ENV" output -json > /tmp/tf_outputs.json
LB_IP=$(jq -r '.load_balancer_ip.value' /tmp/tf_outputs.json)

echo "==> Running configuration management"
ANSIBLE_HOST_KEY_CHECKING=False \
  ansible-playbook -i "$LB_IP," site.yml

echo "==> Deploying workload to k8s"
kubectl --context "$ENV" apply -f k8s/

echo "==> Smoke test"
for i in {1..10}; do
    curl -sf "https://$LB_IP/healthz" && break
    echo "  waiting for healthz... ($i/10)"
    sleep 5
done
echo "Deploy complete."
```
This is the right shape: shell sequences four different tools and makes one pass/fail decision (the health check loop) — it never tries to *be* Terraform or Ansible.

**2. Anti-pattern — reimplementing Terraform's job in bash**
```bash
# BAD: manually checking/creating cloud resources instead of using Terraform
$ cat bad_provision.sh
#!/bin/bash
EXISTS=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=web-01" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -z "$EXISTS" ]; then
    aws ec2 run-instances --image-id ami-0123456 --instance-type t3.medium \
      --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=web-01}]'
fi
# Problems: no drift detection, no state file, no plan/diff before change,
# race conditions if run concurrently, no rollback on partial failure.
# This ENTIRE script is replaced by ~10 lines of Terraform HCL + `terraform apply`.
```

**3. Extracting and passing values between tools with `jq`**
```bash
$ terraform output -json | jq -r '.vpc_id.value'
vpc-0a1b2c3d4e5f
$ VPC_ID=$(terraform output -json | jq -r '.vpc_id.value')
$ aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[].GroupId' --output text
sg-0912a3 sg-0912b4
```

**4. CI entrypoint script (thin, delegates everything)**
```yaml
# .gitlab-ci.yml (excerpt)
deploy_staging:
  stage: deploy
  script:
    - ./ci/deploy.sh staging
```
```bash
$ cat ci/deploy.sh
#!/usr/bin/env bash
set -euo pipefail
env="$1"
./ci/lib/preflight_checks.sh "$env"
./ci/lib/terraform_apply.sh "$env"
./ci/lib/ansible_configure.sh "$env"
./ci/lib/k8s_deploy.sh "$env"
./ci/lib/smoke_test.sh "$env"
```
Each `lib/*.sh` script is small and single-purpose — easy to test, review, and reason about independently.

**5. Where shell legitimately owns a decision: gating on `terraform plan` output**
```bash
$ terraform plan -detailed-exitcode -out=tfplan; rc=$?
$ case $rc in
    0) echo "No changes — skipping apply" ;;
    2) echo "Changes detected — applying"; terraform apply tfplan ;;
    *) echo "terraform plan FAILED"; exit 1 ;;
  esac
```
`-detailed-exitcode` returns 0 = no changes, 1 = error, 2 = changes present — a genuinely good use of shell's exit-code branching to drive pipeline logic.

**6. Portability trap: `sed -i` differs between GNU and BSD**
```bash
$ sed -i 's/foo/bar/' file.txt          # GNU sed (Linux CI runner) — works
$ sed -i 's/foo/bar/' file.txt          # BSD sed (macOS dev laptop) — ERROR:
sed: 1: "file.txt": extra characters at the end of s command
# BSD requires an explicit (even empty) backup suffix:
$ sed -i '' 's/foo/bar/' file.txt       # BSD-compatible form
# Portable fix: use a temp file instead of -i, or detect platform
```

**7. Secret leakage trap in pipeline shell code**
```bash
$ set -x
$ curl -H "Authorization: Bearer $API_TOKEN" https://api.example.com/deploy
+ curl -H 'Authorization: Bearer eyJhbGciOi...REDACTED_BUT_LOGGED' https://api.example.com/deploy
# `set -x` trace output goes straight into CI logs — token now sits in build history.
# Fix: unset -x around sensitive calls, or use --header @headers_file, or a secrets-masking CI feature
$ set +x
$ curl -H "Authorization: Bearer $API_TOKEN" https://api.example.com/deploy
$ set -x
```

**8. When to graduate from shell to Python — a real complexity signal**
```bash
# Started simple...
if [[ "$env" == "prod" ]]; then
    ...
fi
# ...six months later:
if [[ "$env" == "prod" && "$region" == "us-east-1" && "$tier" != "canary" ]]; then
    if aws_quota_check && ! maintenance_window_active && rollback_budget_ok; then
        ...
# This is the signal to stop: extract this decision logic into a small Python
# module with real unit tests, and call it FROM the shell wrapper as one step.
```

## Practice Questions

1. Describe the ideal "shape" of a deployment pipeline that uses Terraform, Ansible, kubectl, and shell together — what does shell own, and what does it explicitly NOT own?
2. Why is reimplementing "check if a cloud resource exists, create it if not" in bash a worse approach than using Terraform, even though it technically works?
3. A teammate's bash deploy script has grown to 800 lines with nested conditionals for environment/region/canary logic. What's your recommendation, and why?
4. How can `set -x` in a CI pipeline accidentally leak secrets, and what are two ways to avoid it?
5. Explain `terraform plan -detailed-exitcode` and how you'd use its exit codes to drive a shell conditional in a pipeline.
6. What's a concrete portability bug that can bite a shell script that works on a Linux CI runner but is later run on a developer's Mac?
7. Why is `jq` almost always paired with shell in IaC pipelines? Give an example of extracting a Terraform output and feeding it into an AWS CLI call.
8. What's wrong with putting secrets directly into a shell variable and passing them as a command-line argument (e.g., `mycli --password "$PASS"`) versus other approaches?
9. Give an example of a decision that IS appropriate for shell to make in a pipeline (a simple, shell-appropriate branch) versus one that ISN'T (should be delegated to Terraform/Ansible/a real language).
10. Why do senior engineers describe shell as "glue code" in this context — what does that metaphor imply about acceptable script size and complexity?

## Interview Key Points

- Core answer to "where does shell fit in IaC pipelines": **orchestration and glue** — sequencing calls to Terraform/Ansible/kubectl/cloud CLIs, parsing their output, making simple pass/fail decisions. Not state management, not complex business logic.
- Reimplementing what Terraform/Ansible already do (idempotent resource creation, drift detection, desired-state reconciliation) in raw shell is a classic red-flag anti-pattern to call out.
- Know the **portability traps**: GNU vs BSD `sed`/`date`/`grep`, `bash` vs `sh`/`dash` (no arrays, no `[[`) in minimal containers — pipelines that work on one CI runner but fail elsewhere.
- Secrets in shell are dangerous by default: `set -x` trace logs, `ps aux` exposing inline CLI args, shell history — know at least two concrete mitigations (masking, `set +x` around sensitive calls, passing via files/stdin not argv).
- `terraform plan -detailed-exitcode` (0/1/2) is a good concrete example of shell exit-code branching driving real pipeline logic — worth having memorized.
- The "graduation" signal: once a shell script needs nested conditionals, structured data, retries with backoff, or real error types, that's the cue to extract logic into Python/Go and call it as one pipeline step — not to keep growing the bash.
- CI entrypoint scripts should be thin (delegate to small single-purpose scripts/tools) — this makes them individually testable and easy to review, versus one monolithic script.
