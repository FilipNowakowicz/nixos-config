#!/usr/bin/env bash
# Build a compact TSV routing index for learning candidates.
set -euo pipefail

root=${1:-.agents/learning}
candidate_dir="$root/candidates"

printf 'path\tid\tstatus\texpires\ttype\troute\tbest_form\tdedupe_key\ttriggers\ttargets\tevidence\trecurrence\n'

[ -d "$candidate_dir" ] || exit 0

candidate_list=$(mktemp)
dedupe_counts=$(mktemp)
trap 'rm -f "$candidate_list" "$dedupe_counts"' EXIT

field_from_path() {
  local path=$1
  local name=$2
  sed -n "s/^${name}:[[:space:]]*//p" "$path" | head -1 |
    tr '\t' ' ' |
    sed "s/^\"//; s/\"$//; s/^'//; s/'$//"
}

find "$candidate_dir" -maxdepth 1 -type f \( -name '*.md' -o -name '*.yml' -o -name '*.yaml' \) |
  sort >"$candidate_list"

while IFS= read -r path; do
  dedupe=$(field_from_path "$path" dedupe_key)
  [ -n "$dedupe" ] && printf '%s\n' "$dedupe"
done <"$candidate_list" |
  sort |
  uniq -c |
  awk '{$1=$1; print}' >"$dedupe_counts"

while IFS= read -r path; do
  field() {
    field_from_path "$path" "$1"
  }

  id=$(field id)
  status=$(field status)
  expires=$(field expires)
  type=$(field type)
  route=$(field route)
  best_form=$(field best_form)
  dedupe_key=$(field dedupe_key)
  triggers=$(field triggers)
  targets=$(field targets)
  evidence=$(field evidence)
  recurrence=1
  if [ -n "$dedupe_key" ]; then
    recurrence=$(awk -v key="$dedupe_key" '$0 ~ /^[0-9]+ / { count=$1; $1=""; sub(/^ /, ""); if ($0 == key) print count }' "$dedupe_counts" | head -1)
    [ -n "$recurrence" ] || recurrence=1
  fi

  [ -n "$id" ] || id=$(basename "$path")
  [ -n "$status" ] || status=unknown

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$path" "$id" "$status" "$expires" "$type" "$route" "$best_form" \
    "$dedupe_key" "$triggers" "$targets" "$evidence" "$recurrence"
done <"$candidate_list"
