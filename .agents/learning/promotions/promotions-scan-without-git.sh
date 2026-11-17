#!/usr/bin/env bash
# Promoted from .agents/learning/candidates/archive/2026-11-16-builder-no-git-vacuous-scan.yml
# validate.sh can run on gcp-builder, which gets the tracked files without .git
# and has no git. A promotion check that lists files with `git ls-files` then
# scans nothing and passes (PR #513). Each one that uses git ls-files must also
# have a find fallback for a tree without .git.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

status=0
checked=0
for promotion in .agents/learning/promotions/*.sh; do
  checked=$((checked + 1))
  if grep -q 'git ls-files' "$promotion" && ! grep -qE '(^|[^[:alnum:]_])find[[:space:]]' "$promotion"; then
    echo "$promotion: lists files with git ls-files and has no find fallback for a tree without .git" >&2
    status=1
  fi
done
if ((checked == 0)); then
  echo "promotions-scan-without-git: no promotion scripts found" >&2
  exit 1
fi
exit "$status"
