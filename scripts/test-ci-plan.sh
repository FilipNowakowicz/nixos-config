#!/usr/bin/env bash
set -euo pipefail

repo_root="$(
  git rev-parse --show-toplevel 2>/dev/null || pwd
)"
cd "$repo_root"

run_plan() {
  local changed_files=$1
  local output_file
  output_file="$(mktemp)"

  GITHUB_EVENT_NAME=pull_request \
    CI_CHANGED_FILES="$changed_files" \
    GITHUB_OUTPUT="$output_file" \
    bash scripts/ci-plan.sh >/dev/null

  cat "$output_file"
  rm -f "$output_file"
}

assert_contains() {
  local haystack=$1
  local needle=$2

  if ! grep -qF "$needle" <<<"$haystack"; then
    echo "Expected planner output to contain: $needle" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack=$1
  local needle=$2

  if grep -qF "$needle" <<<"$haystack"; then
    echo "Expected planner output to exclude: $needle" >&2
    exit 1
  fi
}

docs_output="$(run_plan $'README.md\ndocs/operations.md')"
assert_contains "$docs_output" "docs_only=true"
assert_contains "$docs_output" "run_eval=false"
assert_contains "$docs_output" "run_lint=true"
assert_contains "$docs_output" "run_light=false"
assert_contains "$docs_output" "hosts=false"
assert_contains "$docs_output" "tests=false"
assert_contains "$docs_output" "closure=false"

desktop_output="$(run_plan $'home/neovim/packs/nix.nix')"
assert_contains "$desktop_output" "docs_only=false"
assert_contains "$desktop_output" "run_eval=true"
assert_contains "$desktop_output" "run_lint=true"
assert_contains "$desktop_output" "run_light=true"
assert_contains "$desktop_output" "hosts=true"
assert_contains "$desktop_output" '{"name":"main-ci"}'
assert_contains "$desktop_output" "run_packages=false"

main_output="$(run_plan $'hosts/main/default.nix')"
assert_contains "$main_output" "closure_main=true"
assert_contains "$main_output" '{"name":"main-ci"}'

server_output="$(run_plan $'modules/nixos/profiles/observability/backends.nix')"
assert_contains "$server_output" "tests=true"
assert_contains "$server_output" '{"name":"profile-security","command":"profile-test","target":"profile-security"}'
assert_contains "$server_output" '{"name":"homeserver-gcp-smoke","command":"smoke-homeserver-gcp","target":""}'

homeserver_output="$(run_plan $'hosts/homeserver-gcp/default.nix')"
assert_contains "$homeserver_output" "tests=true"
assert_contains "$homeserver_output" '{"name":"homeserver-gcp-smoke","command":"smoke-homeserver-gcp","target":""}'

installer_output="$(run_plan $'hosts/installer/default.nix')"
assert_contains "$installer_output" "hosts=true"
assert_contains "$installer_output" '{"name":"installer"}'
assert_not_contains "$installer_output" '{"name":"main-ci"}'

package_output="$(run_plan $'packages/inventory-data.nix')"
assert_contains "$package_output" "run_packages=true"
assert_contains "$package_output" "hosts=false"
assert_contains "$package_output" "tests=false"

wsl_output="$(run_plan $'home/users/user/wsl.nix')"
assert_contains "$wsl_output" "docs_only=false"
assert_contains "$wsl_output" "run_eval=true"
assert_contains "$wsl_output" "run_lint=true"
assert_contains "$wsl_output" "run_light=true"
assert_contains "$wsl_output" "run_packages=false"
assert_contains "$wsl_output" "hosts=false"
assert_contains "$wsl_output" "tests=false"

unknown_home_output="$(run_plan $'home/files/misc/unclassified.txt')"
assert_contains "$unknown_home_output" "run_packages=true"
assert_contains "$unknown_home_output" '{"name":"main-ci"}'

unknown_module_output="$(run_plan $'modules/nixos/profiles/unknown.nix')"
assert_contains "$unknown_module_output" "run_packages=true"
assert_contains "$unknown_module_output" "tests=true"
assert_contains "$unknown_module_output" '{"name":"main-ci"}'

closure_output="$(run_plan $'scripts/closure-diff.sh')"
assert_contains "$closure_output" "closure=true"
assert_contains "$closure_output" "closure_main=true"
assert_contains "$closure_output" "hosts=false"

flake_lock_output="$(run_plan $'flake.lock')"
assert_contains "$flake_lock_output" "run_packages=true"
assert_contains "$flake_lock_output" "tests=true"
assert_contains "$flake_lock_output" '{"name":"main-ci"}'

echo "ci-plan tests passed"
