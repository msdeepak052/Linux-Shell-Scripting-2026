# Wrapper/Orchestration Scripts (Terraform, Ansible, `kubectl`, Helm)

Platform teams rarely run `terraform apply` or `helm upgrade` bare — they wrap them in bash for safety checks, consistent flags, logging, and integration with CI/CD and chat notifications.

## Explanation

**Why wrap infra tools at all**: raw CLI invocations vary by person (forgotten `-var-file`, wrong `--namespace`, no plan review before apply). A wrapper script encodes the team's safe-usage rules once, so every invocation — human or CI — gets the same guardrails.

**Terraform wrapper concerns**:
- Always `terraform plan -out=tfplan` then `terraform apply tfplan` — never `apply` directly without a reviewed plan file, especially in CI.
- Parse plan output for `Plan: X to add, Y to change, Z to destroy` to gate on destructive changes (e.g., block auto-apply if `Z > 0` without human approval).
- `terraform workspace select` / `-var-file=envs/prod.tfvars` — explicit environment targeting, never rely on whatever workspace happened to be selected last.
- `TF_IN_AUTOMATION=true` — suppresses interactive prompts/suggests non-interactive-friendly output, standard for CI wrappers.

**Ansible wrapper concerns**:
- Wrap `ansible-playbook` with `--check` (dry-run) as a mandatory first pass before a real run in CI.
- `--limit` to scope which hosts a run touches — a wrapper often forces this to be explicit rather than defaulting to the whole inventory.
- Capture and grep `PLAY RECAP` for `failed=` / `unreachable=` counts to set the wrapper's own exit code (ansible-playbook's own exit code often isn't specific enough for CI gating).
- `ANSIBLE_FORCE_COLOR=0` / `--output=json` (via callback plugins) for machine-parseable output in CI logs.

**`kubectl`/Helm wrapper concerns**:
- Always pass `--namespace`/`--context` explicitly — never rely on the current kubeconfig context in an automation script (classic "deployed to the wrong cluster" incident cause).
- `helm upgrade --install --atomic --wait --timeout 5m` — `--atomic` auto-rolls-back on failed upgrade, `--wait` blocks until resources are ready, essential trio for CI-driven deploys.
- `kubectl apply --dry-run=server` / `helm template | kubeval` — validate manifests before applying.
- `kubectl rollout status deployment/X --timeout=120s` after an apply, to actually confirm the rollout succeeded rather than trusting `apply`'s exit code (which only reflects "API accepted the object," not "pods are healthy").

**General orchestration wrapper pattern**: pre-flight checks -> dry-run/plan -> (optional human/CI gate) -> apply/execute -> post-apply verification -> notify (Slack/webhook) with pass/fail + summary.

## Hands-On Examples

**1. Terraform wrapper: plan -> gate on destroys -> apply**
```bash
$ cat > tf-apply.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
env="${1:?Usage: tf-apply.sh <env>}"

terraform init -input=false
terraform plan -input=false -var-file="envs/${env}.tfvars" -out=tfplan

destroys=$(terraform show -json tfplan | jq '[.resource_changes[] | select(.change.actions == ["delete"])] | length')
if (( destroys > 0 )); then
    echo "WARNING: plan includes $destroys destroy(s). Manual approval required." >&2
    read -rp "Type 'apply' to continue: " confirm
    [[ "$confirm" == "apply" ]] || { echo "Aborted."; exit 1; }
fi

terraform apply -input=false tfplan
EOF
$ ./tf-apply.sh prod
```

**2. Terraform: parsing plan summary for a Slack notification**
```bash
$ summary=$(terraform show tfplan | grep -E '^Plan:' || echo "Plan: no changes")
$ echo "$summary"
Plan: 2 to add, 1 to change, 0 to destroy.
$ curl -sf -X POST -H 'Content-Type: application/json' \
    -d "{\"text\":\"terraform plan (prod): ${summary}\"}" "$SLACK_WEBHOOK_URL"
```

**3. Ansible wrapper: mandatory `--check` pass before real run**
```bash
$ cat > ansible-run.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
playbook="$1"; limit="$2"

echo "== Dry run (--check) =="
ansible-playbook "$playbook" --limit "$limit" --check --diff

read -rp "Dry run looked good. Apply for real? [y/N] " ans
[[ "$ans" == "y" ]] || { echo "Aborted."; exit 1; }

echo "== Real run =="
ansible-playbook "$playbook" --limit "$limit"
EOF
$ ./ansible-run.sh site.yml "webservers"
```

**4. Ansible: gating CI exit code on PLAY RECAP failures**
```bash
$ output=$(ansible-playbook site.yml --limit webservers 2>&1)
$ echo "$output" | tee ansible.log
$ failed=$(echo "$output" | grep -oP 'failed=\K[0-9]+' | tail -1)
$ unreachable=$(echo "$output" | grep -oP 'unreachable=\K[0-9]+' | tail -1)
$ if (( failed > 0 || unreachable > 0 )); then
    echo "Ansible run had failures (failed=$failed unreachable=$unreachable)" >&2
    exit 1
  fi
```

**5. kubectl wrapper: explicit context/namespace + rollout verification**
```bash
$ cat > k8s-deploy.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
context="prod-cluster"
namespace="payments"
image_tag="$1"

kubectl --context "$context" -n "$namespace" \
    set image deployment/payments-api app="registry.internal/payments-api:${image_tag}"

echo "Waiting for rollout..."
if ! kubectl --context "$context" -n "$namespace" rollout status deployment/payments-api --timeout=120s; then
    echo "Rollout failed, rolling back" >&2
    kubectl --context "$context" -n "$namespace" rollout undo deployment/payments-api
    exit 1
fi
echo "Deploy succeeded: payments-api:${image_tag}"
EOF
$ ./k8s-deploy.sh 1.4.3
Waiting for rollout...
deployment "payments-api" successfully rolled out
Deploy succeeded: payments-api:1.4.3
```

**6. Helm wrapper: `--atomic --wait` for safe CI-driven upgrades**
```bash
$ cat > helm-deploy.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
release="$1"; chart="$2"; namespace="$3"; values_file="$4"

helm upgrade --install "$release" "$chart" \
    --namespace "$namespace" --create-namespace \
    --values "$values_file" \
    --atomic --wait --timeout 5m \
    --history-max 10

echo "Release status:"
helm status "$release" -n "$namespace"
EOF
$ ./helm-deploy.sh payments-api ./charts/payments-api payments values-prod.yaml
Release "payments-api" has been upgraded. Happy Helming!
```

**7. Validating manifests before apply (server-side dry-run)**
```bash
$ kubectl --context prod-cluster apply --dry-run=server -f deployment.yaml
deployment.apps/payments-api configured (server dry run)

$ helm template payments-api ./charts/payments-api -f values-prod.yaml | kubeval --strict
PASS - deployment.yaml contains a valid Deployment
```

**8. Full orchestration: pre-flight -> plan -> apply -> verify -> notify**
```bash
$ cat > release.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
tag="$1"

notify() { curl -sf -X POST -d "{\"text\":\"$1\"}" "$SLACK_WEBHOOK_URL" >/dev/null; }
trap 'notify "Release ${tag} FAILED at line $LINENO"' ERR

echo "Pre-flight: checking image exists"
docker manifest inspect "registry.internal/payments-api:${tag}" >/dev/null

echo "Deploying via Helm"
helm upgrade --install payments-api ./charts/payments-api \
    --namespace payments --set image.tag="${tag}" --atomic --wait --timeout 5m

echo "Verifying rollout"
kubectl -n payments rollout status deployment/payments-api --timeout=120s

notify "Release ${tag} succeeded"
EOF
```

## Practice Questions

1. Why should a Terraform wrapper always run `plan -out=tfplan` followed by `apply tfplan`, rather than running `terraform apply` directly in CI?
2. Write the `jq` filter to count destroy actions from `terraform show -json tfplan`, and explain why a wrapper might block auto-apply above a certain destroy threshold.
3. Why is `ansible-playbook`'s own exit code often insufficient for CI gating, and what do you parse from `PLAY RECAP` instead?
4. Explain why a `kubectl`/Helm wrapper should never rely on the ambient kubeconfig current-context, and what real incident this guards against.
5. What do `--atomic`, `--wait`, and `--timeout` do in `helm upgrade --install`, and why are all three necessary together for a safe CI-driven deploy?
6. Why does checking `kubectl apply`'s exit code alone NOT confirm a deployment is actually healthy? What command do you run afterward, and what does it actually wait for?
7. Design a wrapper script's control flow for a Terraform apply that needs a human approval gate only when the plan includes destroys, but should auto-apply otherwise. Sketch the logic.
8. Why would you run `ansible-playbook --check --diff` before a real run, and what class of bugs does this NOT catch (i.e., what's the limitation of check mode)?
9. In the Helm wrapper example, what happens if the upgrade fails partway through with `--atomic` set? What would happen differently without it?
10. Explain the value of a `trap 'notify ...' ERR` pattern in an orchestration script — how does it improve on manually adding a notify call after every risky step?

## Interview Key Points

- Wrapper scripts exist to enforce guardrails uniformly — plan-before-apply, explicit environment targeting, and dry-run-before-real-run are the three most commonly expected patterns across Terraform/Ansible/kubectl/Helm.
- Never trust `kubectl apply`'s exit code as proof of a healthy deployment — it only confirms the API server accepted the object. `kubectl rollout status` is the real health signal, and interviewers specifically probe for this distinction.
- `helm upgrade --install --atomic --wait --timeout` is close to a required answer when asked "how do you safely deploy via Helm in CI" — know what each flag individually buys you (create-if-missing, auto-rollback-on-failure, block-until-ready).
- Explicit `--context`/`--namespace`/`-var-file`/`--limit` everywhere — automation must never depend on ambient/default state (current kubeconfig context, current terraform workspace, whole inventory) because that state differs per operator/CI runner.
- Gating destructive changes (Terraform destroys, mass Ansible changes) behind an explicit approval step is a strong "production maturity" signal — know how to parse plan/output to detect risk before applying.
- `trap ... ERR` for centralized failure notification is a clean pattern worth naming — it avoids scattering the same notify-on-failure call after every command.
- Ansible's own process exit code conflates several failure classes; parsing `PLAY RECAP` for `failed=`/`unreachable=` counts is the practical way CI wrappers get a precise pass/fail signal.
