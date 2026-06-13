#!/usr/bin/env bash
set -euo pipefail

repo_root="$(
  git rev-parse --show-toplevel 2>/dev/null || pwd
)"
cd "$repo_root"

# The real `main` nixosConfiguration pulls in pkgs.displaylink, a `requireFile`
# blob CI can neither fetch nor substitute (see
# modules/nixos/hardware/displaylink.nix). Building its
# config.system.build.toplevel fails before any check runs, so every
# CI-required scripts/validate.sh command must build `main-ci` instead.
#
# The only sanctioned reference to the real `main` closure is build_host()'s
# `main | main-full` case in scripts/validate.sh, used by
# `validate.sh host main[-full]` for local deploys and the post-merge R2
# cache-priming step in .github/workflows/nix.yml (both run where the blob is
# already available/cached).
FORBIDDEN_PATTERN='nixosConfigurations\.main\.config\.system\.build\.toplevel'

usage() {
  cat <<'EOF'
Usage: check-ci-closure-targets.sh
       check-ci-closure-targets.sh --self-test

Asserts that CI-required scripts/validate.sh commands build `main-ci`
(profiles.ci = true) rather than the real `main`, whose closure references an
unfetchable requireFile blob (pkgs.displaylink).
EOF
}

# Prints "<line>: <content>" for every line outside [start,end] in $file that
# matches FORBIDDEN_PATTERN.
find_violations() {
  local file=$1 start=$2 end=$3
  awk -v s="$start" -v e="$end" \
    '(NR < s || NR > e) { print NR": "$0 }' "$file" |
    grep -E "$FORBIDDEN_PATTERN" || true
}

check_validate_sh() {
  local file=$1
  local start end violations

  start=$(grep -n '^build_host() {' "$file" | head -n1 | cut -d: -f1)
  if [[ -z $start ]]; then
    echo "check-ci-closure-targets: $file: build_host() function not found" >&2
    return 1
  fi

  end=$(awk -v start="$start" 'NR > start && /^}/ { print NR; exit }' "$file")
  if [[ -z $end ]]; then
    echo "check-ci-closure-targets: $file: build_host() closing brace not found" >&2
    return 1
  fi

  violations=$(find_violations "$file" "$start" "$end")
  if [[ -n $violations ]]; then
    echo "check-ci-closure-targets: $file references the real (displaylink-bearing)" >&2
    echo "'main' closure outside build_host()'s 'main | main-full' case:" >&2
    echo "$violations" >&2
    echo "CI-required commands must build 'main-ci' instead (see modules/nixos/hardware/displaylink.nix)." >&2
    return 1
  fi
}

# Workflow files dispatch to scripts/validate.sh; no workflow should bypass it
# with an inline reference to the real `main` closure.
check_workflows() {
  local violations
  violations=$(grep -RnE "$FORBIDDEN_PATTERN" .github/workflows/ || true)
  if [[ -n $violations ]]; then
    echo "check-ci-closure-targets: workflow file references the real (displaylink-bearing)" >&2
    echo "'main' closure directly instead of going through scripts/validate.sh:" >&2
    echo "$violations" >&2
    return 1
  fi
}

self_test() {
  local tmp bad
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' EXIT

  if ! check_validate_sh scripts/validate.sh; then
    echo "self-test: expected scripts/validate.sh to pass as-is" >&2
    return 1
  fi

  if ! check_workflows; then
    echo "self-test: expected .github/workflows/ to pass as-is" >&2
    return 1
  fi

  # Inject a violation into a copy of validate.sh: a CI-required command
  # (hosts) builds the real `main` closure instead of `main-ci`.
  bad="$tmp/validate.sh"
  cp scripts/validate.sh "$bad"
  sed -i '/^hosts)$/a\  build_attrs ".#nixosConfigurations.main.config.system.build.toplevel"' "$bad"

  if check_validate_sh "$bad"; then
    echo "self-test: expected injected 'hosts' violation to fail" >&2
    return 1
  fi

  echo "check-ci-closure-targets: self-test passed"
}

case "${1:-}" in
--self-test)
  self_test
  ;;
-h | --help)
  usage
  ;;
"")
  check_validate_sh scripts/validate.sh
  check_workflows
  echo "check-ci-closure-targets: CI closure targets are clean"
  ;;
*)
  usage >&2
  exit 1
  ;;
esac
