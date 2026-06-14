#!/usr/bin/env bash
# Query the compact candidate index without opening candidate bodies.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  printf 'usage: %s <query terms...>\n' "$(basename "$0")" >&2
  exit 2
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
query=$*
tmp=${TMPDIR:-/tmp}/learning-index-$$.tsv
trap 'rm -f "$tmp"' EXIT

"$script_dir/index-candidates.sh" "$root" >"$tmp"

{
  head -1 "$tmp"
  tail -n +2 "$tmp" |
    awk -F "\t" -v query="$query" '
      BEGIN {
        n = split(tolower(query), terms, /[[:space:]]+/)
      }
      {
        line = tolower($0)
        score = 0
        for (i = 1; i <= n; i++) {
          if (terms[i] != "" && index(line, terms[i]) > 0) {
            score++
          }
        }
        if (score > 0) {
          recurrence = $NF
          if (recurrence !~ /^[0-9]+$/) {
            recurrence = 1
          }
          print score "\t" recurrence "\t" $0
        }
      }
    ' |
    sort -t "$(printf '\t')" -k1,1rn -k2,2rn |
    cut -f3- ||
    true
} |
  head -6
