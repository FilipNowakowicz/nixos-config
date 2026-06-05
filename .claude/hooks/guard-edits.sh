#!/usr/bin/env bash
# PreToolUse guard for Edit/Write/MultiEdit/NotebookEdit.
#
# This is the safety net for bypass-permissions mode: with prompts off, this
# hook is the only deterministic thing between the agent and a destructive or
# secret-leaking edit. Keep it FAST and LOW-NOISE — it must never fire during
# normal work, only on genuinely-bad targets.
#
# Behaviour:
#   deny  — direct edits to encrypted/secret material (use `sops` instead)
#   ask   — edits to disko.nix (destructive on apply; force one confirmation)
#   allow — everything else falls through (exit 0, no output)
set -euo pipefail

input=$(cat)

if command -v jq >/dev/null 2>&1; then
  path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty')
else
  path=$(printf '%s' "$input" |
    grep -oE '"(file_path|notebook_path|path)"[[:space:]]*:[[:space:]]*"[^"]*"' |
    head -1 |
    sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' || true)
fi

emit() { # $1=permissionDecision  $2=reason
  local reason
  reason=$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$reason"
  exit 0
}

check_path() {
  local path="$1"
  [ -z "${path:-}" ] && return 0
  local base
  base=$(basename "$path")

  # Secret material — always block, route through sops.
  case "$path" in
  *.enc | *.age)
    emit deny "Refusing direct edit of encrypted/secret file '$base'. Edit it with: sops '$path'"
    ;;
  */secrets/* | secrets/*)
    emit deny "Refusing direct edit under a secrets/ directory ('$path'). Edit via sops, not the raw file."
    ;;
  esac
  case "$path" in
  */sops/age/keys.txt)
    emit deny "Refusing to edit the age private key ('$path')."
    ;;
  esac

  # Destructive disk layout — force one confirmation even under bypass.
  case "$base" in
  disko.nix)
    emit ask "disko.nix controls on-disk partitioning and is DESTRUCTIVE on apply. Confirm this is a metadata-only change for a future reinstall, not a live repartition."
    ;;
  esac
}

check_path "$path"

# Codex may route edits through apply_patch-style payloads instead of a direct
# file_path. Scan string fields for patch headers and apply the same path rules.
if command -v jq >/dev/null 2>&1; then
  patch_paths=$(printf '%s' "$input" |
    jq -r '.. | strings' |
    sed -nE 's/^\*\*\* (Add|Update|Delete) File: (.*)$/\2/p')
else
  patch_paths=$(printf '%s' "$input" |
    sed -nE 's/.*\*\*\* (Add|Update|Delete) File: ([^\\"]+).*/\2/p')
fi

if [ -n "${patch_paths:-}" ]; then
  while IFS= read -r patch_path; do
    check_path "$patch_path"
  done <<<"$patch_paths"
fi

exit 0
