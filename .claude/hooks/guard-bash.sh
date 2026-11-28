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
#           top-level path, a redirect into a raw disk device, or an admin
#           PR merge (`gh pr merge --admin` bypasses merge-gate and races the
#           homeserver deploy gate; only the user decides to force-merge)
#   deny  — a plain nix build or flake check on a host that can offload to gcp-builder
#   allow — everything else falls through (exit 0, no output)
set -uo pipefail

builder_key=${GUARD_BASH_BUILDER_KEY:-/run/secrets/gcp_builder_build_key}

if [ "${1:-}" = --self-test ]; then
  script=$0 key=$(mktemp)
  trap 'rm -f "$key"' EXIT
  decision() {
    local out
    out=$(jq -n --arg c "$1" '{tool_input:{command:$c}}' | GUARD_BASH_BUILDER_KEY=$key bash "$script")
    if [ -z "$out" ]; then echo allow; else jq -r .hookSpecificOutput.permissionDecision <<<"$out"; fi
  }
  expect() { # $1=decision $2=command
    local got
    got=$(decision "$2")
    [ "$got" = "$1" ] || {
      printf 'guard-bash self-test: expected %s, got %s for: %s\n' "$1" "$got" "$2" >&2
      exit 1
    }
  }
  expect deny 'nix build .#checks.x86_64-linux.foo --no-link'
  expect deny 'cd /x && nix flake check'
  expect allow 'nix build .#foo --dry-run'
  expect allow 'LOCAL_BUILD=1 nix build .#foo'
  expect allow 'bash scripts/on-builder.sh nix build .#foo'
  expect allow 'nix eval .#foo'
  # Commit messages that mention a build on their own line (multi-line quotes
  # and heredoc bodies) are text, not commands.
  expect allow $'git commit -m "Fix it\n\nnix build .#foo passes now"'
  expect allow $'git commit -F - <<\'EOF\'\nFix it\n\nnix build .#foo passes now\nEOF'
  expect deny $'cat <<EOF >x\nbody\nEOF\nnix build .#foo'
  expect ask 'gh pr merge 12 --admin'
  reason=$(jq -n '{tool_input:{command:"nix build .#checks.x86_64-linux.foo"}}' |
    GUARD_BASH_BUILDER_KEY=$key bash "$script" | jq -r .hookSpecificOutput.permissionDecisionReason)
  case "$reason" in
  *"bash scripts/on-builder.sh nix build .#checks.x86_64-linux.foo"*) ;;
  *)
    echo "guard-bash self-test: deny reason lacks the on-builder command: $reason" >&2
    exit 1
    ;;
  esac
  echo "guard-bash self-test passed"
  exit 0
fi

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

# Drop heredoc bodies and quoted spans (including multi-line ones, hence
# sed -z) so words inside commit messages and strings can't be mistaken for a
# command. Handles simple, non-escaped quoting — enough for this purpose.
dequoted=$(printf '%s\n' "$cmd" | awk '
  delim != "" { line = $0; sub(/^\t+/, "", line); if (line == delim) delim = ""; next }
  { print }
  match($0, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*/) && substr($0, RSTART, 3) != "<<<" {
    delim = substr($0, RSTART, RLENGTH); sub(/^<<-?[[:space:]]*["\047]?/, "", delim)
  }' | sed -Ez "s/\"[^\"]*\"//g; s/'[^']*'//g")

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
    [ -e "$builder_key" ]; then
    emit deny "Run heavy Nix work on gcp-builder: use scripts/validate.sh, or run: bash scripts/on-builder.sh ${words[*]:i}$([ "$dequoted" = "$cmd" ] || echo ' (re-add any quoted arguments)'). nix eval, path-info and --dry-run are not blocked. Prefix with LOCAL_BUILD=1 only if the builder is unavailable (for example no CPU quota free)."
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
  gh)
    matches "$stmt" '(^|[[:space:]])pr[[:space:]]+merge([[:space:]]|$)' &&
      matches "$stmt" '(^|[[:space:]])--admin([[:space:]=]|$)' &&
      emit ask "'gh pr merge --admin' bypasses branch protection and merge-gate. Only admin-merge when the user explicitly asked for it; otherwise merge normally or use --auto."
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
