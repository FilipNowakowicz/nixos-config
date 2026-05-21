#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <label> <restored-bytes> <hit>" >&2
  exit 1
fi

label=$1
restored_bytes=$2
hit=$3
summary_file=${GITHUB_STEP_SUMMARY:-}

if [[ -z $summary_file ]]; then
  echo "GITHUB_STEP_SUMMARY is not set" >&2
  exit 1
fi

saved_bytes=0
if command -v nix >/dev/null 2>&1; then
  saved_bytes="$(
    nix path-info --json --json-format 2 --all 2>/dev/null |
      python3 -c 'import json, sys; data = json.load(sys.stdin); info = data.get("info", {}); print(sum(int(item.get("narSize", 0)) for item in info.values() if isinstance(item, dict)))'
  )"
fi

format_bytes() {
  local bytes=$1

  if command -v numfmt >/dev/null 2>&1; then
    local value
    value="$(numfmt --to=iec --suffix=B --format="%.1f" "$bytes")"
    case "$value" in
    *KB | *MB | *GB | *TB | *PB)
      printf '%s %s\n' "${value%?B}" "${value#"${value%?B}"}"
      ;;
    *)
      printf '%s\n' "$value"
      ;;
    esac
    return
  fi

  echo "${bytes} B"
}

printf '%s cache: restored %s, saved %s, hit=%s\n' \
  "$label" \
  "$(format_bytes "$restored_bytes")" \
  "$(format_bytes "$saved_bytes")" \
  "$hit" >>"$summary_file"
