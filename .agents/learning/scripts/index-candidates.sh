#!/usr/bin/env bash
# Build a compact TSV routing index for learning candidates.
set -euo pipefail

field_from_path() {
  local path=$1
  local name=$2
  sed -n "s/^${name}:[[:space:]]*//p" "$path" | head -1 |
    tr '\t' ' ' |
    sed "s/^\"//; s/\"$//; s/^'//; s/'$//"
}

build_index() {
  local root=${1:-.agents/learning}
  local candidate_dir="$root/candidates"

  printf 'path\tid\tstatus\texpires\ttype\troute\tbest_form\tdedupe_key\ttriggers\ttargets\tevidence\trecurrence\n'

  [ -d "$candidate_dir" ] || return 0

  local candidate_list dedupe_counts
  candidate_list=$(mktemp)
  dedupe_counts=$(mktemp)
  trap 'rm -f "$candidate_list" "$dedupe_counts"' RETURN

  find "$candidate_dir" -maxdepth 1 -type f \( -name '*.md' -o -name '*.yml' -o -name '*.yaml' \) |
    sort >"$candidate_list"

  while IFS= read -r path; do
    local dedupe
    dedupe=$(field_from_path "$path" dedupe_key)
    if [ -n "$dedupe" ]; then
      printf '%s\n' "$dedupe"
    fi
  done <"$candidate_list" |
    sort |
    uniq -c |
    awk '{$1=$1; print}' >"$dedupe_counts"

  while IFS= read -r path; do
    field() {
      field_from_path "$path" "$1"
    }

    local id status expires type route best_form dedupe_key triggers targets evidence recurrence
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
}

self_test() {
  local tmp out rc
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/candidates"
  cat >"$tmp/candidates/a-first.yml" <<'EOF'
id: a-first
status: open
dedupe_key: shared-key
EOF
  # Last candidate in sorted order intentionally lacks a dedupe_key, the
  # regression case for the issue where the dedupe-counting loop's exit
  # status killed the script under set -euo pipefail.
  cat >"$tmp/candidates/b-last.yml" <<'EOF'
id: b-last
status: open
EOF

  set +e
  out=$(build_index "$tmp")
  rc=$?
  set -e
  [[ $rc -eq 0 ]] || {
    echo "self-test: build_index exited $rc, expected 0" >&2
    return 1
  }

  local rows
  rows=$(printf '%s\n' "$out" | tail -n +2 | wc -l)
  [[ $rows -eq 2 ]] || {
    echo "self-test: expected 2 rows, got $rows" >&2
    return 1
  }
  printf '%s\n' "$out" | grep -Fq $'\ta-first\t' ||
    {
      echo "self-test: missing row for a-first" >&2
      return 1
    }
  printf '%s\n' "$out" | grep -Fq $'\tb-last\t' ||
    {
      echo "self-test: missing row for b-last (last-candidate-no-dedupe-key case)" >&2
      return 1
    }

  printf 'index-candidates self-test passed\n'
}

if [[ ${1:-} == --self-test ]]; then
  self_test
  exit $?
fi

build_index "${1:-.agents/learning}"
