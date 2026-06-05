#!/usr/bin/env bash
# Return a ranked, compact file list for repo exploration.
set -euo pipefail

usage() {
  printf 'usage: %s [--limit N] <query terms...>\n' "$(basename "$0")" >&2
}

limit=${REPO_MAP_LIMIT:-12}
if [ "${1:-}" = "--limit" ]; then
  [ "$#" -ge 3 ] || {
    usage
    exit 2
  }
  limit=$2
  shift 2
fi

if [ "$#" -eq 0 ]; then
  usage
  exit 2
fi

case "$limit" in
'' | *[!0-9]*)
  printf 'limit must be a positive integer\n' >&2
  exit 2
  ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$repo_root"

hits_tmp=${TMPDIR:-/tmp}/repo-map-hits-$$.tsv
trap 'rm -f "$hits_tmp"' EXIT

# The index is derived purely from tracked paths, so it only changes when the
# set of tracked files changes. Cache it per file-set (cksum of the file list)
# so repeated queries within a session skip the rebuild; content edits don't
# invalidate it because the index never reads file contents.
ls_key=$(git ls-files | cksum | tr -d ' ')
index_tmp=${TMPDIR:-/tmp}/repo-map-index-${ls_key}.tsv
[ -s "$index_tmp" ] || "$script_dir/index.sh" >"$index_tmp"
: >"$hits_tmp"

for term in "$@"; do
  [ -n "$term" ] || continue
  (
    git grep -n -I -F -i -- "$term" \
      -- \
      ':!flake.lock' \
      ':!**/*.lock' \
      ':!.agents/learning/candidates/*' \
      ':!.agents/repo-map/*' \
      ':!.agents/skills/repo-map-query/*' \
      2>/dev/null || true
  ) |
    awk -v term="$term" -F ':' 'NF >= 3 { print tolower(term) "\t" $1 "\t" $2 }' \
      >>"$hits_tmp"
done

awk -F '\t' -v query="$*" '
  BEGIN {
    n = split(tolower(query), terms, /[[:space:]]+/)
    for (i = 1; i <= n; i++) {
      if (terms[i] != "") {
        wanted++
      }
    }
  }
  FILENAME == ARGV[1] {
    if (FNR == 1) {
      next
    }
    path = $1
    meta[path] = $0
    area[path] = $2
    kind[path] = $3
    line = tolower($0)
    for (i = 1; i <= n; i++) {
      term = terms[i]
      if (term != "" && index(line, term) > 0) {
        score[path] += 4
        matched[path] = append_once(matched[path], term)
      }
    }
    next
  }
  {
    term = $1
    path = $2
    ref = $2 ":" $3
    if (!(path in meta)) {
      next
    }
    hit_key = path SUBSEP term
    hit_count[hit_key]++
    if (hit_count[hit_key] <= 5) {
      score[path] += 2
    }
    matched[path] = append_once(matched[path], term)
    if (ref_count[path] < 6) {
      refs[path] = append_once(refs[path], ref)
      ref_count[path]++
    }
  }
  END {
    print "score\tpath\tarea\tkind\tmatched\trefs"
    for (path in meta) {
      if (score[path] > 0) {
        matched_count = split(matched[path], matched_parts, ",")
        final_score = score[path] + (matched_count * 3)
        if (wanted > 1 && matched_count >= wanted) {
          final_score += 8
        }
        print final_score "\t" path "\t" area[path] "\t" kind[path] "\t" matched[path] "\t" refs[path]
      }
    }
  }
  function append_once(existing, value, parts, count, i) {
    if (value == "") {
      return existing
    }
    if (existing == "") {
      return value
    }
    count = split(existing, parts, ",")
    for (i = 1; i <= count; i++) {
      if (parts[i] == value) {
        return existing
      }
    }
    return existing "," value
  }
' "$index_tmp" "$hits_tmp" |
  {
    IFS= read -r header
    printf '%s\n' "$header"
    sort -t "$(printf '\t')" -k1,1rn -k2,2 |
      awk -v limit="$limit" 'NR <= limit'
  }
