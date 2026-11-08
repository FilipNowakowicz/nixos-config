#!/usr/bin/env bash
# Runs inside the disposable builder checkout. No cloud credentials are needed.
set -euo pipefail

# The transfer intentionally omits .git and untracked files. Give Git-dependent
# light checks an index over exactly this snapshot, without copying credentials.
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  git init -q
  git add .
fi

for selector in PLAN_LIGHT PLAN_PACKAGES PLAN_HOSTS PLAN_TESTS; do
  case ${!selector:-false} in
  true | false) ;;
  *)
    echo "Invalid selector: $selector" >&2
    exit 2
    ;;
  esac
done

parallel=${CI_BUILDER_JOBS:-4}
[[ $parallel =~ ^[1-9][0-9]*$ && $parallel -le 16 ]] || {
  echo 'Invalid CI_BUILDER_JOBS' >&2
  exit 2
}
log_dir=$(mktemp -d "${TMPDIR:-/tmp}/ci-builder-logs.XXXXXX")
trap 'rm -rf "$log_dir"' EXIT
names=()
commands=()
targets=()
add_check() {
  names+=("$1")
  commands+=("$2")
  targets+=("${3:-}")
}

[[ ${PLAN_LIGHT:-false} != true ]] || add_check light light
[[ ${PLAN_PACKAGES:-false} != true ]] || add_check packages package all
if [[ ${PLAN_HOSTS:-false} == true ]]; then
  # Command substitutions propagate jq's status; process substitution would not.
  rows=$(jq -er '.include[] | .name' <<<"$PLAN_HOSTS_MATRIX")
  while IFS= read -r host; do
    case $host in
    main-ci | installer) add_check "host-$host" host "$host" ;;
    *)
      echo "Unexpected CI host: $host" >&2
      exit 2
      ;;
    esac
  done <<<"$rows"
fi
if [[ ${PLAN_TESTS:-false} == true ]]; then
  rows=$(jq -er '.include[] | [.name, .command, .target] | @tsv' <<<"$PLAN_TESTS_MATRIX")
  while IFS=$'\t' read -r name command target; do
    case "$name:$command:$target" in
    profile-security:profile-test:profile-security | profile-observability:profile-test:profile-observability | profile-hardening:profile-test:profile-hardening | profile-runtime-timezone:profile-test:profile-runtime-timezone | homeserver-gcp-smoke:smoke-homeserver-gcp: | quiet-shell-smoke:smoke-quiet-shell:)
      add_check "$name" "$command" "$target"
      ;;
    *)
      echo "Unexpected CI test: $name/$command/$target" >&2
      exit 2
      ;;
    esac
  done <<<"$rows"
fi

pids=()
joined=0
failed=0
wait_check() {
  local index=$1 rc=0
  wait "${pids[index]}" || rc=$?
  if [[ $rc == 0 ]]; then
    echo "PASS ${names[index]} ($(cat "$log_dir/$index.seconds")s)"
  else
    echo "FAIL ${names[index]} (exit $rc)"
    echo "::group::${names[index]} failure log"
    cat "$log_dir/$index.log"
    echo '::endgroup::'
    failed=1
  fi
}

for index in "${!names[@]}"; do
  echo "START ${names[index]}: bash scripts/validate.sh ${commands[index]} ${targets[index]}"
  (
    trap - EXIT
    started=$SECONDS
    rc=0
    # Capture the command itself, not tee/cat's status. Every child is joined.
    ON_BUILDER=1 bash scripts/validate.sh "${commands[index]}" "${targets[index]}" >"$log_dir/$index.log" 2>&1 || rc=$?
    echo "$((SECONDS - started))" >"$log_dir/$index.seconds"
    exit "$rc"
  ) &
  pids+=("$!")
  if ((index >= parallel - 1)); then
    wait_check "$joined"
    joined=$((joined + 1))
  fi
done
for ((index = joined; index < ${#names[@]}; index++)); do
  wait_check "$index"
done
printf 'Builder finished %d planned checks; failed=%d\n' "${#names[@]}" "$failed"
exit "$failed"
