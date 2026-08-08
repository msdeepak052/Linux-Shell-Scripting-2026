# CI/CD Shell Scripting Patterns (Jenkins, GitLab CI, GitHub Actions)

CI/CD pipelines are, underneath the YAML, mostly shell scripts glued together by a scheduler — knowing the platform-specific quirks (exit-code handling, secrets, env var propagation) is what makes pipelines actually reliable.

## Explanation

**Cross-platform fundamentals**:
- Every pipeline step is ultimately a shell invocation; a non-zero exit code fails the step (and usually the pipeline) unless explicitly ignored.
- `set -euo pipefail` belongs in every non-trivial CI shell step for the same reasons as any production script — CI YAML `script:`/`run:` blocks default to a much looser shell mode otherwise.
- Secrets are injected as environment variables by the CI platform — never `echo` them, and mask/scrub them from logs; most platforms auto-mask known secret vars but custom-derived secrets (e.g., a token built from parts) won't be caught.
- Passing data **between steps/jobs** requires the platform's own mechanism (files/artifacts, or platform-specific "output" variables) — plain shell env vars set in one step do NOT survive into the next step/job by default (each step often runs in a fresh shell).

**Jenkins (Groovy pipeline + `sh` steps)**:
- `sh` step runs `/bin/sh` by default unless you use `sh(script: '...', returnStdout: true)`/`#!/usr/bin/env bash` shebang inside a multi-line script — `sh '''...'''` blocks are literal shell scripts.
- `sh(returnStatus: true)` captures exit code without failing the build immediately, letting Groovy decide how to react.
- `withCredentials([...])` binds secrets to env vars scoped to that block only — the standard secret-handling pattern.
- Jenkins swallows/masks credentials bound via `withCredentials` in console output automatically; anything NOT bound that way is not masked.

**GitLab CI (`.gitlab-ci.yml`)**:
- Each `script:` line runs in the same shell session within a job, but each **job** runs in a fresh container/shell — use `artifacts:` to pass files between jobs, or `dotenv` artifact reports to pass variables.
- `before_script`/`after_script` run in the same shell context as `script` (mostly) — good place for common setup/teardown.
- `rules:`/`only`/`except` control whether a job runs at all — often combined with shell logic inside the job itself for finer-grained conditionals (e.g., checking a changed-files list).
- CI/CD variables marked "Protected"/"Masked" — masked variables get scrubbed from job logs automatically, but only if they don't contain characters that break masking (newlines, etc.).

**GitHub Actions**:
- `run:` steps default to `bash --noprofile --noninteractive -e {0}` on Linux runners (note: `-e` is on by default, but NOT `-u`/`pipefail` — add `set -euo pipefail` yourself for full strictness).
- `$GITHUB_ENV` — append `KEY=value` to this file to set an env var visible to **later steps** in the same job.
- `$GITHUB_OUTPUT` — append `name=value` to this file to set a step **output**, consumable by other steps/jobs via `${{ steps.x.outputs.name }}` / `needs.job.outputs.name`.
- `::add-mask::value` (legacy) or writing to `$GITHUB_OUTPUT`/env carefully — secrets set via `secrets.X` are auto-masked in logs; anything derived (e.g., base64-decoded) is NOT automatically masked unless you explicitly mask it.
- `continue-on-error: true` at the step level vs handling exit codes inside the script — different failure-propagation semantics worth knowing.

## Hands-On Examples

**1. Strict-mode CI step (GitHub Actions) — don't rely on platform defaults alone**
```yaml
- name: Build and test
  run: |
    set -euo pipefail
    npm ci
    npm run build
    npm test
```

**2. Passing a computed value between GitHub Actions steps via `$GITHUB_OUTPUT`**
```yaml
- name: Determine version
  id: version
  run: |
    set -euo pipefail
    version=$(jq -r '.version' package.json)
    echo "version=${version}" >> "$GITHUB_OUTPUT"

- name: Build tagged image
  run: docker build -t "myapp:${{ steps.version.outputs.version }}" .
```

**3. GitLab CI: passing variables between jobs via `dotenv` artifact**
```yaml
build:
  stage: build
  script:
    - set -euo pipefail
    - echo "IMAGE_TAG=$(git rev-parse --short HEAD)" >> build.env
  artifacts:
    reports:
      dotenv: build.env

deploy:
  stage: deploy
  needs: [build]
  script:
    - echo "Deploying image tag ${IMAGE_TAG}"
    - helm upgrade --install app ./chart --set image.tag="${IMAGE_TAG}"
```

**4. Jenkins: capturing exit status without immediately failing the build**
```groovy
stage('Integration Tests') {
    steps {
        script {
            def rc = sh(script: './run-integration-tests.sh', returnStatus: true)
            if (rc != 0) {
                echo "Integration tests failed with code ${rc}, marking build UNSTABLE"
                currentBuild.result = 'UNSTABLE'
            }
        }
    }
}
```

**5. Jenkins: secret handling with `withCredentials`**
```groovy
withCredentials([string(credentialsId: 'docker-registry-token', variable: 'REGISTRY_TOKEN')]) {
    sh '''
        set -euo pipefail
        echo "$REGISTRY_TOKEN" | docker login registry.internal --username ci --password-stdin
        docker push registry.internal/myapp:latest
    '''
}
```

**6. Detecting which files changed to conditionally run a step (common in monorepos)**
```bash
$ changed_files=$(git diff --name-only "$CI_MERGE_REQUEST_DIFF_BASE_SHA"...HEAD)
$ if echo "$changed_files" | grep -q '^services/payments/'; then
    echo "Payments service changed — running its test suite"
    (cd services/payments && ./run-tests.sh)
  else
    echo "No changes under services/payments — skipping"
  fi
```

**7. Masking a derived secret manually (GitHub Actions) — auto-masking doesn't cover computed values**
```yaml
- name: Decode and use deploy key
  run: |
    set -euo pipefail
    key=$(echo "$DEPLOY_KEY_B64" | base64 -d)
    echo "::add-mask::$key"
    echo "$key" > /tmp/deploy_key
    chmod 600 /tmp/deploy_key
```

**8. Retrying a flaky CI step (network-dependent) with backoff, standard pattern**
```bash
$ cat > ci-retry.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
attempt=1; max=3
until npm publish; do
    if (( attempt >= max )); then
        echo "npm publish failed after $max attempts" >&2
        exit 1
    fi
    echo "Publish attempt $attempt failed, retrying..." >&2
    sleep $((attempt * 5))
    ((attempt++))
done
EOF
```

## Practice Questions

1. Why doesn't a plain `export FOO=bar` in one GitHub Actions step make `$FOO` visible in the next step, and what mechanism actually propagates it?
2. Compare how GitLab CI and GitHub Actions each pass data/variables between separate jobs (not steps within a job). Name the specific mechanism for each.
3. GitHub Actions `run:` steps use `bash -e` by default — what does this NOT give you compared to full `set -euo pipefail`, and why would you still add it explicitly?
4. In Jenkins, what's the difference between `sh 'command'` and `sh(script: 'command', returnStatus: true)`? When would you use the latter?
5. Why are secrets injected via `withCredentials` (Jenkins) or `secrets.X` (GitHub Actions) auto-masked in logs, but a base64-decoded or otherwise derived value is NOT automatically masked? How do you handle that case?
6. Write a shell snippet for a monorepo CI pipeline that only runs a service's test suite if files under its directory changed in the current diff.
7. What's the practical difference between a CI step failing outright versus using `continue-on-error: true` (GitHub Actions) or `allow_failure: true` (GitLab CI)? When is each appropriate?
8. Why should you never `echo` a secret variable in a CI script "just for debugging," even temporarily? What's the realistic blast radius if you do?
9. Design a retry wrapper for a flaky, network-dependent CI step (e.g., `npm publish` or `docker push`), and explain why exponential backoff is preferable to a fixed retry interval in this context.
10. A GitLab CI job's `script:` succeeds but the pipeline still shows red. What CI-specific reasons (beyond the script's own exit code) could cause this — think about `after_script`, artifact upload failures, or job timeout?

## Interview Key Points

- Each CI platform has its own mechanism for passing values between steps/jobs — `$GITHUB_ENV`/`$GITHUB_OUTPUT` (GitHub Actions), `dotenv` artifact reports (GitLab CI), `withCredentials`/`env` bindings and shared workspace files (Jenkins). Confusing these is a very common real-world bug.
- Default shell strictness differs by platform (GitHub Actions gives you `-e` but not `-u`/`pipefail`; Jenkins `sh` steps get whatever `/bin/sh` or bash defaults to) — always add `set -euo pipefail` explicitly rather than trusting platform defaults.
- Auto-masking of secrets only covers values the platform knows about verbatim — anything derived (decoded, concatenated, transformed) needs manual masking (`::add-mask::` in GitHub Actions) or must never be echoed at all.
- Passing data between **jobs** (not just steps) always requires an explicit mechanism (artifacts, dotenv reports, outputs) because jobs typically run in fresh containers/shells with no shared process state.
- Retry-with-backoff for flaky network-dependent CI steps (package publish, image push, external API calls) is an expected pattern — know how to write it and justify exponential over fixed-interval backoff.
- Understand the distinction between a step's shell exit code failing the job outright versus `continue-on-error`/`allow_failure` — and the operational implications of silently allowing a step to fail (green pipeline hiding a real problem).
- Monorepo-aware conditional execution (only test/deploy what changed) is a common senior-level pattern interviewers probe for — know how to derive a changed-files list via `git diff` and gate steps on it.
