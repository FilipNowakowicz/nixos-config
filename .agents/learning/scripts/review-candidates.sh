#!/usr/bin/env bash
# Summarize learning candidates for reviewer triage without opening bodies.
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=${1:-.agents/learning}
today=${LEARNING_TODAY:-$(date +%F)}
tmp=${TMPDIR:-/tmp}/learning-review-$$.tsv
trap 'rm -f "$tmp"' EXIT

"$script_dir/index-candidates.sh" "$root" >"$tmp"

printf 'Learning candidate review index (%s)\n\n' "$today"

printf 'Status counts:\n'
tail -n +2 "$tmp" |
  awk -F '\t' '{ count[$3 == "" ? "unknown" : $3]++ } END { for (k in count) print count[k], k }' |
  sort -k2

printf '\nOpen candidates by route/form:\n'
tail -n +2 "$tmp" |
  awk -F '\t' '$3 == "open" { key = ($6 == "" ? "unknown" : $6) "/" ($7 == "" ? "unknown" : $7); count[key]++ } END { for (k in count) print count[k], k }' |
  sort -k2

printf '\nExpired open candidates:\n'
tail -n +2 "$tmp" |
  awk -F '\t' -v today="$today" '$3 == "open" && $4 != "" && $4 < today { print $1 "\t" $2 "\t" $4 "\t" $6 "/" $7 }' |
  sort -k3 ||
  true

printf '\nOpen candidate rows:\n'
head -1 "$tmp"
tail -n +2 "$tmp" |
  awk -F '\t' '$3 == "open"' |
  sort -t "$(printf '\t')" -k6,6 -k7,7 -k4,4 -k2,2
