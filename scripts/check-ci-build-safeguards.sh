#!/usr/bin/env bash
# Enforce that every heavy build job in the Nix workflow carries the two
# runner-survival safeguards: a `timeout-minutes:` cap and the
# "Reclaim runner disk space" step.
#
# "Heavy build job" = any job whose steps invoke `scripts/validate.sh package`
# or `scripts/validate.sh host`. Those build full system closures and the
# installer ISO (the largest disk consumers in CI), so they must both free the
# ~20-30GB of preinstalled runner bloat before building and cap their runtime
# instead of inheriting the 6h default.
#
# Motivation: PR #360's `packages` job died ~49min into the ISO build with an
# evicted log blob (BlobNotFound) — the signature of an abnormal runner death
# (disk-full/OOM) — because it was the only heavy build job missing both
# safeguards. PR #361 added them; this gate keeps any future heavy job from
# regressing the same way.
set -euo pipefail

repo_root="$(
  git rev-parse --show-toplevel 2>/dev/null || pwd
)"
cd "$repo_root"

workflow=".github/workflows/nix.yml"
reclaim_marker="Reclaim runner disk space"

if [[ ! -f $workflow ]]; then
  echo "Workflow not found: $workflow" >&2
  exit 1
fi

# Emit "<job>\t<body>" for each top-level job block (2-space-indented key under
# `jobs:`), with the body's newlines flattened to \x01 so each job is one line.
job_blocks="$(
  awk '
    /^jobs:[[:space:]]*$/ { injobs = 1; next }
    injobs && /^[^[:space:]#]/ { injobs = 0 }            # left the jobs: section
    !injobs { next }
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {                  # new job header
      if (job != "") print job "\t" body
      job = $1; sub(/:$/, "", job)
      body = ""
      next
    }
    { body = body $0 "\x01" }
    END { if (job != "") print job "\t" body }
  ' "$workflow"
)"

fail=0
checked=0

while IFS=$'\t' read -r job body; do
  [[ -n $job ]] || continue
  # Restore newlines for grep.
  decoded="${body//$'\x01'/$'\n'}"

  grep -qE 'scripts/validate\.sh (package|host)' <<<"$decoded" || continue
  checked=$((checked + 1))

  if ! grep -qE '^[[:space:]]*timeout-minutes:' <<<"$decoded"; then
    echo "FAIL: heavy build job '$job' is missing timeout-minutes" >&2
    fail=1
  fi
  if ! grep -qF "$reclaim_marker" <<<"$decoded"; then
    echo "FAIL: heavy build job '$job' is missing the '$reclaim_marker' step" >&2
    fail=1
  fi
done <<<"$job_blocks"

if [[ $checked -eq 0 ]]; then
  echo "No heavy build jobs (validate.sh package|host) found in $workflow." >&2
  echo "The detection rule likely drifted; update this check." >&2
  exit 1
fi

if [[ $fail -ne 0 ]]; then
  echo "Add 'timeout-minutes:' and the '$reclaim_marker' step to the job(s) above." >&2
  echo "See the 'hosts'/'packages' jobs for the canonical form." >&2
  exit 1
fi

echo "ci build safeguards present ($checked heavy build job(s) checked)"
