# Testing Shell Scripts (`bats`, `shunit2`)

Shell scripts run in production just like any other code — they deserve the same automated test discipline, and `bats`/`shunit2` are how you actually get it.

## Explanation

**Why test shell scripts at all?** Because they routinely run in production (deploy scripts, cron jobs, health checks, CI glue) and are notoriously easy to break silently: a typo'd variable under `set -u`, an off-by-one in a loop, a `grep` pattern that stops matching after a log format change. Without tests, the only "test suite" is production itself.

**`bats` (Bash Automated Testing System)** is the de facto standard for testing bash. Tests are `.bats` files — bash with a thin TAP-producing DSL layered on top (`@test "description" { ... }`). Each test runs in its own subshell, and assertions are just exit codes: a test passes if every command inside it exits 0 (or the last command's exit status is 0), following bash's own truthiness. `bats-support`/`bats-assert` add nicer assertion helpers (`assert_success`, `assert_output`, `assert_line`).

**`shunit2`** is an older, xUnit-style framework (ported from JUnit conventions) — you write `testXxx()` functions in a shell script, source `shunit2` at the bottom, and it discovers and runs them, with `setUp`/`tearDown` hooks and `assertEquals`/`assertTrue`/`assertFalse` assertions. It's more portable (works with plain `sh`, not just bash) and is a common choice when a codebase needs to test POSIX `sh` scripts, not just bashisms.

**Core testing patterns for shell scripts:**
- **Isolate side effects.** Never let tests touch real systems — mock external commands, use temp directories (`mktemp -d`), and clean up in teardown.
- **Test functions, not just whole-script behavior.** Structure scripts so logic lives in sourceable functions (`source script.sh` without running `main`), so tests can call individual functions directly rather than only invoking the whole script as a subprocess.
- **Mock external commands by shadowing them.** Define a fake `curl`/`aws`/`kubectl` function or a stub script earlier in `$PATH` that returns canned output, so tests don't need real network/cloud access.
- **Test exit codes explicitly**, not just stdout — a script that prints the right message but returns exit 0 on failure is a common shell bug.
- **Run tests in CI** exactly like any other test suite — `bats` and `shunit2` both produce parseable output (TAP for bats) that CI systems understand natively.

**Structuring a script to be testable** is the single biggest lever: a script that's one giant `main` body with no functions is nearly untestable except as a black box (run it, check exit code + stdout). A script broken into small functions (`validate_args`, `fetch_data`, `write_output`) can be `source`d and each function tested independently — the same "small, pure, testable units" principle from any other language, applied to bash.

## Hands-On Examples

**1. Installing bats and basic project layout**
```bash
$ sudo apt install bats            # or: git clone bats-core + bats-support + bats-assert as submodules
$ tree tests/
tests/
├── deploy.bats
└── test_helper/
    ├── bats-support
    └── bats-assert
```

**2. A minimal bats test file**
```bash
$ cat tests/deploy.bats
#!/usr/bin/env bats

setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    export TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "script exits 0 on valid input" {
    run ./deploy.sh staging
    assert_success
}

@test "script exits 1 when environment arg is missing" {
    run ./deploy.sh
    assert_failure
    assert_output --partial "Usage: deploy.sh"
}

$ bats tests/deploy.bats
 ✓ script exits 0 on valid input
 ✓ script exits 1 when environment arg is missing

2 tests, 0 failures
```
`run` captures the command's exit code into `$status` and output into `$output`/`$lines`, without letting a failure abort the test file (important since bash would otherwise just exit).

**3. Testing a sourced function directly (not the whole script)**
```bash
$ cat lib/validate.sh
validate_env() {
    case "$1" in
        staging|production) return 0 ;;
        *) echo "Invalid environment: $1" >&2; return 1 ;;
    esac
}

$ cat tests/validate.bats
#!/usr/bin/env bats

setup() {
    source lib/validate.sh
}

@test "accepts staging as valid" {
    run validate_env "staging"
    [ "$status" -eq 0 ]
}

@test "rejects garbage input" {
    run validate_env "banana"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid environment"* ]]
}

$ bats tests/validate.bats
 ✓ accepts staging as valid
 ✓ rejects garbage input

2 tests, 0 failures
```

**4. Mocking an external command (`aws` CLI) so tests don't hit real infra**
```bash
$ cat tests/fixtures/aws
#!/bin/bash
# Fake aws CLI stub — returns canned JSON regardless of args
echo '{"Reservations":[{"Instances":[{"InstanceId":"i-0abc123"}]}]}'

$ cat tests/get_instance.bats
#!/usr/bin/env bats

setup() {
    export PATH="$PWD/tests/fixtures:$PATH"   # fake `aws` shadows the real one
}

@test "extracts instance ID from aws output" {
    run ./get_instance_id.sh
    assert_success
    assert_output "i-0abc123"
}

$ bats tests/get_instance.bats
 ✓ extracts instance ID from aws output

1 test, 0 failures
```

**5. shunit2 — xUnit-style testing, portable to plain `sh`**
```bash
$ cat tests/test_math.sh
#!/bin/sh

add() { echo $(( $1 + $2 )); }

testAddition() {
    result=$(add 2 3)
    assertEquals "5" "$result"
}

testAdditionWithNegative() {
    result=$(add 5 -3)
    assertEquals "2" "$result"
}

# Must be the LAST line — shunit2 discovers and runs all testXxx functions
. shunit2

$ sh tests/test_math.sh
testAddition
testAdditionWithNegative

Ran 2 tests.

OK
```

**6. shunit2 with `setUp`/`tearDown` and a temp workspace**
```bash
$ cat tests/test_backup.sh
#!/bin/bash

oneTimeSetUp() {
    export WORKDIR=$(mktemp -d)
}

oneTimeTearDown() {
    rm -rf "$WORKDIR"
}

setUp() {
    touch "$WORKDIR/data.txt"
}

tearDown() {
    rm -f "$WORKDIR/data.txt" "$WORKDIR/data.txt.bak"
}

testBackupCreatesBackupFile() {
    ./backup.sh "$WORKDIR/data.txt"
    assertTrue "backup file should exist" "[ -f '$WORKDIR/data.txt.bak' ]"
}

. shunit2

$ bash tests/test_backup.sh
testBackupCreatesBackupFile

Ran 1 test.

OK
```

**7. Testing exit codes AND output together — catching a "prints error but exits 0" bug**
```bash
$ cat broken_healthcheck.sh
#!/bin/bash
curl -sf http://localhost:8080/health || echo "Health check failed"
# BUG: no `exit 1` after the echo — script always exits 0

$ cat tests/healthcheck.bats
@test "healthcheck exits non-zero on failure" {
    run ./broken_healthcheck.sh   # assume port 8080 is closed in test env
    assert_failure                # THIS FAILS — exposes the bug
    assert_output --partial "Health check failed"
}

$ bats tests/healthcheck.bats
 ✗ healthcheck exits non-zero on failure
   (in test file tests/healthcheck.bats, line 2)
     `assert_failure' failed
   -- command succeeded, but it was expected to fail --
   status : 0
   output : Health check failed

1 test, 1 failure
```
This is exactly the class of bug tests catch that manual testing misses — the script "looks right" when you eyeball its output, but the exit code (what a caller/orchestrator actually checks) is wrong.

**8. Wiring bats into CI**
```yaml
# .github/workflows/test.yml (excerpt)
- name: Run bats tests
  run: |
    sudo apt-get install -y bats
    bats --tap tests/*.bats
```
```bash
$ bats --tap tests/*.bats
1..5
ok 1 script exits 0 on valid input
ok 2 script exits 1 when environment arg is missing
not ok 3 healthcheck exits non-zero on failure
ok 4 accepts staging as valid
ok 5 rejects garbage input
```
`--tap` output is directly consumable by most CI test-result parsers, same as any other language's test runner.

## Practice Questions

1. Why does `run` in bats matter — what would happen to a test file if you called a failing command directly instead of wrapping it in `run`?
2. How would you restructure a monolithic 200-line deploy script to make its core logic unit-testable with bats, without changing its runtime behavior?
3. Describe how you'd mock the `kubectl` command in a bats test so a test suite doesn't require a real cluster.
4. What's the practical difference between `bats` and `shunit2` in terms of shell portability (bash-only vs POSIX `sh`), and when would that matter for choosing one?
5. Write a bats test that verifies a script exits with code 2 specifically when a required config file is missing (not just "any non-zero code").
6. A script silently swallows a `curl` failure and always exits 0. Write a bats test that would catch this bug before it reaches production.
7. What do `setUp`/`tearDown` (shunit2) and `setup`/`teardown` (bats) let you guarantee about test isolation, and why does that matter when tests touch temp files or environment variables?
8. How would you test a function that calls `date` or generates a timestamp, given that the output changes every time it runs?
9. Why is testing exit codes just as important as testing stdout/stderr output for shell scripts specifically (versus, say, testing a REST API)?
10. Your team has zero test coverage on a critical set of ops scripts. What's your prioritization strategy for where to add tests first?

## Interview Key Points

- Core justification for testing shell: it runs in production (deploys, cron, health checks) just like any other code, and is unusually prone to silent bugs (typos under `set -u`, exit-code mishandling, brittle `grep`/`sed` patterns).
- `bats` = bash-only, TAP-producing, most common in modern CI-driven shops. `shunit2` = xUnit-style, portable to POSIX `sh`, useful when scripts must run under `dash`/minimal shells too. Know this distinction — it's a common "which would you pick and why" question.
- **Structuring scripts as sourceable functions** (rather than one monolithic `main` body) is the single biggest lever for testability — mention this proactively, it signals real experience.
- **Mocking external commands by shadowing `$PATH`** (a fake `aws`/`kubectl`/`curl` earlier in PATH) is the standard technique for isolating shell tests from real infrastructure — know this pattern cold.
- Always test **exit codes explicitly**, not just printed output — the classic shell bug is a script that prints an error message but forgets `exit 1`, so callers/orchestrators (which only check `$?`) never see the failure.
- `run` (bats) captures `$status`/`$output`/`$lines` without letting a failing command abort the test — know why this matters (bash would otherwise treat a failing command as fatal to the test script).
- Both frameworks produce CI-friendly output (bats: TAP via `--tap`) — testing shell scripts should be a normal part of the same CI pipeline as any other language, not a manual afterthought.
