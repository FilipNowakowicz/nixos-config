#!/usr/bin/env bash
# SessionStart hook (Claude and Codex): a few lines of orientation so an agent
# knows, before its first command, whether it is in the shared primary checkout
# and which other worktrees and branches are in use. Several agents share ~/nix,
# and editing the primary checkout or reusing a busy branch clobbers their work.
#
# Prints nothing and exits 0 outside a git repo. No network, so it stays fast.
set -uo pipefail

input=$(cat 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
cd "${cwd:-.}" 2>/dev/null || exit 0
top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
primary=$(dirname "$common")

branch=$(git branch --show-current 2>/dev/null)
dirty=$(git status --porcelain 2>/dev/null | wc -l)
lines=("Checkout: $top on ${branch:-detached HEAD}, $dirty uncommitted path(s).")
if [[ $top == "$primary" ]]; then
  lines+=("This is the shared primary checkout: edit in a worktree under ~/.local/share/worktrees/<repo>/<branch> instead.")
fi
others=$(git worktree list --porcelain 2>/dev/null |
  awk -v top="$top" '/^worktree /{w=$2} /^branch /{b=$2; sub("refs/heads/","",b); if (w != top) print b}' |
  head -12 | paste -sd' ' -)
[[ -z $others ]] || lines+=("Branches checked out in other worktrees (do not reuse): $others")

text=$(printf '%s\n' "${lines[@]}")
jq -cn --arg t "$text" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $t}}'
