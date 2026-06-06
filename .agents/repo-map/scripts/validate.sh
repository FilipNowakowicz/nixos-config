#!/usr/bin/env bash
# Validate repo-map helpers and run a small query smoke test.
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

bash -n "$script_dir/index.sh" "$script_dir/query.sh"

rows=$("$script_dir/index.sh" | wc -l)
if [ "$rows" -le 1 ]; then
  printf 'repo-map index did not return tracked files\n' >&2
  exit 1
fi

if ! "$script_dir/query.sh" --limit 3 validate docs | awk 'NR > 1 { found = 1 } END { exit found ? 0 : 1 }'; then
  printf 'repo-map query smoke test returned no matches\n' >&2
  exit 1
fi
