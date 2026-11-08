#!/usr/bin/env bash
# PreToolUse guard for Bash. Companion to guard-edits.sh and the second half of
# the bypass-permissions safety net: it *asks* (one confirmation) before running
# unambiguously catastrophic, hard-to-undo operations.
#
# It keys on the *command name* of each statement, not on arbitrary text in the
# line — so a commit message, echo, or grep that merely mentions "mkfs"/"rm -rf
# /nix" does not trip it. Quoted strings are stripped before scanning for the
# same reason. Patterns are deliberately narrow: false silence beats nagging.
#
#   ask   — destructive block-device ops, LUKS format/erase, recursive rm of a
#           top-level path, or a redirect into a raw disk device
#   deny  — a plain nix build or flake check on a host that can offload to gcp-builder
#   allow — everything else falls through (exit 0, no output)
set -uo pipefail

input=$(cat)

if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
else
  cmd=$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p')
fi

[ -z "${cmd:-}" ] && exit 0

emit() { # $1=permissionDecision  $2=reason
  local reason
  reason=$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$reason"
  exit 0
}

matches() { printf '%s' "$1" | grep -Eq "$2"; }

# Drop quoted spans so words inside messages/strings can't be mistaken for a
# command (handles simple, non-escaped quoting — enough for this purpose).
dequoted=$(printf '%s' "$cmd" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")

# A redirect into a raw disk device, anywhere in the (de-quoted) command.
if matches "$dequoted" '>[[:space:]]*/dev/(sd|nvme|vd|mmcblk|disk)'; then
  emit ask "This redirects output into a raw disk device (/dev/...), which overwrites it. Confirm the target."
fi

# Inspect each statement's leading command name.
statements=$(printf '%s' "$dequoted" | sed -E 's/(\|\||&&|[;|&\n])/\n/g')
while IFS= read -r stmt; do
  read -ra words <<<"$stmt"
  i=0 name=""
  while [ "$i" -lt "${#words[@]}" ]; do
    name="${words[$i]}"
    case "$name" in
    sudo | doas | env | command | nice | ionice | nohup | time) ;;
    *=*) ;;
    *)
      break
      ;;
    esac
    i=$((i + 1))
    name=""
  done
  [ -z "$name" ] && continue
  base=$(basename -- "$name")

  # Heavy Nix work belongs on gcp-builder. A dry run or an explicitly offloaded
  # build is fine, and LOCAL_BUILD=1 deliberately overrides this.
  if [ "$base" = nix ] && matches "$stmt" '(^|[[:space:]])nix[[:space:]]+(build|flake[[:space:]]+check)([[:space:]]|$)' &&
    ! matches "$stmt" '(--dry-run|--no-build|--max-jobs[[:space:]]+0|-j[[:space:]]*0)([[:space:]]|$)' &&
    ! matches "$cmd" '(^|[[:space:];&|])LOCAL_BUILD=1[[:space:]]' &&
    [ -e /run/secrets/gcp_builder_build_key ]; then
    emit deny "Run heavy Nix work on gcp-builder: use scripts/validate.sh, or bash scripts/on-builder.sh nix build ... for anything else. Prefix with LOCAL_BUILD=1 only if it must build on this machine."
  fi

  case "$base" in
  mkfs | mkfs.* | wipefs | blkdiscard | sgdisk | sfdisk)
    emit ask "'$base' is a destructive block-device / filesystem operation. Double-check the target device before proceeding."
    ;;
  parted | fdisk)
    matches "$stmt" '/dev/' && emit ask "'$base' on a /dev/ target can repartition a disk. Confirm the device."
    ;;
  dd)
    matches "$stmt" 'of=/dev/' && emit ask "dd writing to a raw device (of=/dev/...) overwrites it. Confirm the target device."
    ;;
  shred)
    matches "$stmt" '/dev/' && emit ask "shred against a /dev/ target destroys the device contents. Confirm the target."
    ;;
  cryptsetup)
    matches "$stmt" 'luksFormat|luksErase|luksRemoveKey|luksKillSlot|(^|[[:space:]])erase' &&
      emit ask "This cryptsetup command destroys LUKS data or key slots and is not reversible. Confirm the device and slot."
    ;;
  rm)
    if matches "$stmt" '(-[[:alnum:]]*[rR]|--recursive)' &&
      matches "$stmt" '(^|[[:space:]])/(nix|persist|home|boot)?(/?\*?)?([[:space:]]|$)'; then
      emit ask "This looks like a recursive rm targeting a top-level path (/, /nix, /persist, /home, or /boot). Confirm the target is what you intend."
    fi
    ;;
  esac
done <<<"$statements"

exit 0
