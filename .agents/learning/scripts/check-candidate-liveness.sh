#!/usr/bin/env bash
# Heuristic: has a candidate's evidence already landed?
#
# Reviewers re-derived this by hand — git-archaeology each implement-fix
# candidate to see whether the fix was already merged before promoting it. This
# automates the cheap signals: commit SHAs in `evidence` that are ancestors of
# HEAD, and PR numbers that GitHub reports as merged. It advises only; the
# reviewer still decides (promote / superseded / reject). It never edits files.
#
# This repo squash-merges, so a pre-merge commit SHA is NOT an ancestor of main
# after its PR lands — a "#NNN merged" reference is the more reliable signal.
# Evidence that cites neither a SHA nor a PR yields NO SIGNAL: that is a capture
# gap, not a clean bill of health, and still needs manual judgement.
#
# Usage:
#   check-candidate-liveness.sh            # open candidates (the actionable set)
#   check-candidate-liveness.sh all        # every candidate regardless of status
#   check-candidate-liveness.sh <substr>   # candidates whose id/path matches substr
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$script_dir/.." && pwd)

filter=${1:-__open__}
tmp=${TMPDIR:-/tmp}/learning-liveness-$$.tsv
trap 'rm -f "$tmp"' EXIT

"$script_dir/index-candidates.sh" "$root" >"$tmp"

have_gh=0
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  have_gh=1
fi

printf 'Candidate liveness (heuristic — verify before acting)\n'
[ "$have_gh" -eq 1 ] || printf '(gh unavailable: PR merge state not checked)\n'
printf '\n'

# Columns from index-candidates.sh:
# 1 path 2 id 3 status 4 expires 5 type 6 route 7 best_form
# 8 dedupe_key 9 triggers 10 targets 11 evidence
tail -n +2 "$tmp" | while IFS=$'\t' read -r path id status _expires _type route best_form _dk _trig targets evidence; do
  case "$filter" in
  __open__) [ "$status" = "open" ] || continue ;;
  all) ;;
  *) case "$id$path" in *"$filter"*) ;; *) continue ;; esac ;;
  esac

  signals=""
  resolved=0

  # Commit SHAs: validate each hex token is a real commit (filters sha256
  # hashes and store paths), then test ancestry against HEAD.
  for sha in $(printf '%s\n' "$evidence" | grep -oE '\b[0-9a-f]{7,40}\b' | sort -u); do
    git -C "$root" rev-parse --verify --quiet "${sha}^{commit}" >/dev/null 2>&1 || continue
    if git -C "$root" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
      signals+="    commit ${sha} -> ancestor of HEAD (landed)\n"
      resolved=1
    else
      signals+="    commit ${sha} -> known commit, NOT on HEAD\n"
    fi
  done

  # PR references (#NNN). Only meaningful with gh.
  if [ "$have_gh" -eq 1 ]; then
    for pr in $(printf '%s\n' "$evidence" | grep -oE '#[0-9]+' | tr -d '#' | sort -u); do
      state=$(gh pr view "$pr" --json state --jq .state 2>/dev/null || true)
      [ -n "$state" ] || continue
      signals+="    PR #${pr} -> ${state}\n"
      [ "$state" = "MERGED" ] && resolved=1
    done
  fi

  if [ "$resolved" -eq 1 ]; then
    verdict="LIKELY RESOLVED — consider 'superseded'; do not re-implement"
  elif [ -n "$signals" ]; then
    verdict="UNRESOLVED — evidence pointers exist but none have landed"
  else
    verdict="NO SIGNAL — no commit/PR pointer; judge from evidence + targets"
  fi

  printf '%s  [%s/%s]  status=%s\n' "$id" "$route" "$best_form" "$status"
  [ -n "$signals" ] && printf '%b' "$signals"
  printf '  verdict: %s\n' "$verdict"
  [ -n "$targets" ] && printf '  targets: %s\n' "$targets"
  printf '\n'
done
