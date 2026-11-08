#!/usr/bin/env bash
# A successful builder can replace only the four planned heavy job families.
set -euo pipefail
fail=0
require_result() {
  local name=$1 expected=$2 actual=$3
  if [[ $actual != "$expected" ]]; then
    echo "FAIL: $name expected $expected, got $actual"
    fail=1
  fi
}
require_result push-policy success "$RESULT_PUSH_POLICY"
if [[ $fail == 0 && $POLICY_SHOULD_RUN == false ]]; then
  echo "Skipping merge gate: $POLICY_REASON"
  exit 0
fi
require_result changes success "$RESULT_CHANGES"

builder_handled=false
case "$RESULT_BUILDER:${BUILDER_AVAILABLE:-false}:${BUILDER_COMPLETED:-false}" in
success:true:true) builder_handled=true ;;
success:false:false | skipped:false:false) ;;
*)
  echo "FAIL: builder ($RESULT_BUILDER), available=${BUILDER_AVAILABLE:-false}, completed=${BUILDER_COMPLETED:-false}"
  fail=1
  ;;
esac

require_when_planned() {
  local name=$1 planned=$2 result=$3 heavy=${4:-false}
  local expected=skipped
  if [[ $planned == true ]]; then
    if [[ $heavy != true || $builder_handled != true ]]; then expected=success; fi
  elif [[ $planned != false ]]; then
    echo "FAIL: invalid plan for $name: $planned"
    fail=1
  fi
  require_result "$name" "$expected" "$result"
}
require_when_planned eval "$PLAN_EVAL" "$RESULT_EVAL"
require_when_planned lint "$PLAN_LINT" "$RESULT_LINT"
require_when_planned checks-light "$PLAN_LIGHT" "$RESULT_CHECKS_LIGHT" true
require_when_planned packages "$PLAN_PACKAGES" "$RESULT_PACKAGES" true
require_when_planned hosts "$PLAN_HOSTS" "$RESULT_HOSTS" true
require_when_planned tests "$PLAN_TESTS" "$RESULT_TESTS" true
if [[ $builder_handled == true && $PLAN_LIGHT != true && $PLAN_PACKAGES != true && $PLAN_HOSTS != true && $PLAN_TESTS != true ]]; then
  echo 'FAIL: builder ran with no planned heavy checks'
  fail=1
fi
exit "$fail"
