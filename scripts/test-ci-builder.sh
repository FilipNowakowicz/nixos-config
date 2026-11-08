#!/usr/bin/env bash
# Deterministic dispatch/failure contracts; no GCP, SSH or real builds.
set -euo pipefail
repo_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/repo/scripts"
cp "$repo_root/scripts/ci-builder-checks.sh" "$test_dir/repo/scripts/"
export TEST_EVENTS="$test_dir/events"
cat >"$test_dir/repo/scripts/validate.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ $ON_BUILDER == 1 ]]
printf 'start:%s:%s\n' "$1" "$2" >> "$TEST_EVENTS"
sleep 0.1
printf 'end:%s:%s\n' "$1" "$2" >> "$TEST_EVENTS"
if [[ $1 == "${TEST_FAIL_COMMAND:-}" ]]; then
  echo 'intentional-check-failure'
  exit 42
fi
STUB
cd "$test_dir/repo"
export PLAN_LIGHT=true PLAN_PACKAGES=true PLAN_HOSTS=true PLAN_TESTS=true
export PLAN_HOSTS_MATRIX='{"include":[{"name":"main-ci"},{"name":"installer"}]}'
export PLAN_TESTS_MATRIX='{"include":[{"name":"profile-security","command":"profile-test","target":"profile-security"}]}'
rc=0
TEST_FAIL_COMMAND=light bash scripts/ci-builder-checks.sh >"$test_dir/fail.log" 2>&1 || rc=$?
[[ $rc == 1 ]]
grep -q 'FAIL light (exit 42)' "$test_dir/fail.log"
grep -q 'intentional-check-failure' "$test_dir/fail.log"
grep -q 'PASS profile-security' "$test_dir/fail.log"
[[ $(wc -l <"$TEST_EVENTS") == 10 ]]
# At least two commands started before the first completed.
awk -F: '/^start:/ { n++ } /^end:/ { exit n < 2 }' "$TEST_EVENTS"
: >"$TEST_EVENTS"
bash scripts/ci-builder-checks.sh >"$test_dir/pass.log"
[[ $(wc -l <"$TEST_EVENTS") == 10 ]]

# Docs-only: the same planned selectors launch no remote work.
: >"$TEST_EVENTS"
PLAN_LIGHT=false PLAN_PACKAGES=false PLAN_HOSTS=false PLAN_TESTS=false bash scripts/ci-builder-checks.sh >"$test_dir/docs.log"
[[ ! -s $TEST_EVENTS ]]
# Bad matrices cannot silently turn a planned family into an empty success.
rc=0
PLAN_HOSTS_MATRIX='broken JSON' bash scripts/ci-builder-checks.sh >/dev/null 2>&1 || rc=$?
[[ $rc != 0 ]]

# Gate truth table, including fail-closed behavior after successful readiness.
export RESULT_PUSH_POLICY=success POLICY_SHOULD_RUN=true POLICY_REASON=test RESULT_CHANGES=success
export PLAN_EVAL=true PLAN_LINT=true RESULT_EVAL=success RESULT_LINT=success
export RESULT_BUILDER=success BUILDER_AVAILABLE=true BUILDER_COMPLETED=true
export RESULT_CHECKS_LIGHT=skipped RESULT_PACKAGES=skipped RESULT_HOSTS=skipped RESULT_TESTS=skipped
bash "$repo_root/scripts/ci-merge-gate.sh"
expect_gate_failure() {
  local rc=0
  "$@" bash "$repo_root/scripts/ci-merge-gate.sh" >"$test_dir/gate.log" 2>&1 || rc=$?
  [[ $rc == 1 ]] || {
    echo 'Gate unexpectedly accepted invalid results'
    exit 1
  }
}
expect_gate_failure env RESULT_BUILDER=failure BUILDER_COMPLETED=false
expect_gate_failure env RESULT_BUILDER=cancelled
expect_gate_failure env BUILDER_COMPLETED=false
expect_gate_failure env RESULT_EVAL=failure
expect_gate_failure env RESULT_LINT=skipped
# Unreachable and fork/label skips require all planned fallback jobs to pass.
export BUILDER_AVAILABLE=false BUILDER_COMPLETED=false
expect_gate_failure env RESULT_BUILDER=success
export RESULT_CHECKS_LIGHT=success RESULT_PACKAGES=success RESULT_HOSTS=success RESULT_TESTS=success
bash "$repo_root/scripts/ci-merge-gate.sh"
RESULT_BUILDER=skipped bash "$repo_root/scripts/ci-merge-gate.sh"
expect_gate_failure env RESULT_BUILDER=failure
expect_gate_failure env RESULT_TESTS=failure
expect_gate_failure env RESULT_PUSH_POLICY=failure POLICY_SHOULD_RUN=false
# Docs-only runs only lint; an unexpected builder run is rejected.
PLAN_LIGHT=false PLAN_PACKAGES=false PLAN_HOSTS=false PLAN_TESTS=false PLAN_EVAL=false \
  RESULT_CHECKS_LIGHT=skipped RESULT_PACKAGES=skipped RESULT_HOSTS=skipped RESULT_TESTS=skipped RESULT_EVAL=skipped \
  RESULT_BUILDER=skipped bash "$repo_root/scripts/ci-merge-gate.sh"

cd "$repo_root"
# Assert the workflow boundaries as well as exercising the scripts they call.
workflow=.github/workflows/nix.yml
grep -q "github.event.pull_request.head.repo.full_name == github.repository" "$workflow"
grep -q "!contains(github.event.pull_request.labels.\*.name, 'skip-builder')" "$workflow"
grep -q 'args: --accept-dns=false' "$workflow"
[[ $(grep -c 'needs: \[push-policy, changes, builder\]' "$workflow") == 4 ]]
# The new scripts are part of the planner's shared-module/full-validation path.
bash scripts/test-ci-plan.sh
bash scripts/test-on-builder.sh
echo 'CI builder and merge-gate contract tests passed'
