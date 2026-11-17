#!/usr/bin/env bash
# Promoted from .agents/learning/candidates/archive/2026-09-27-scheduled-workflow-silent-failure.yml
# An expired API key turned the scheduled ACL drift check red for seven weeks
# with nobody told. Every workflow with a schedule must report its failures
# through .github/actions/report-scheduled-failure, which needs issues: write.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

status=0
scheduled=0
for workflow in .github/workflows/*.yml .github/workflows/*.yaml; do
  [[ -f $workflow ]] || continue
  grep -qE '^[[:space:]]+schedule:' "$workflow" || continue
  scheduled=$((scheduled + 1))
  if ! grep -q 'uses: ./.github/actions/report-scheduled-failure' "$workflow"; then
    echo "$workflow: scheduled, but a failed run reports nowhere (add the report-scheduled-failure step)" >&2
    status=1
  elif ! grep -q 'issues: write' "$workflow"; then
    echo "$workflow: reports failures but lacks issues: write" >&2
    status=1
  fi
done
if ((scheduled == 0)); then
  echo "scheduled-workflows-report-failure: no scheduled workflows found; refusing to pass on an empty scan" >&2
  exit 1
fi
exit "$status"
