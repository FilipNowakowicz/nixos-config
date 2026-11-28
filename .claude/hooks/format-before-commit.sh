#!/usr/bin/env bash
# PreToolUse hook for Bash (Claude and Codex): format changed files before a
# `git commit`, so a formatter failure is caught here instead of in CI.
#
# Linked worktrees not entered through `nix develop` have no pre-commit config,
# and agents commit there with --no-verify, so treefmt never ran and CI's
# `nix fmt --fail-on-change` failed instead (#576, #577). This hook runs
# `nix fmt` on the changed files of the repo being committed; if that changed
# anything it denies the commit and says which files to look at and re-add.
#
# Only for repos with a flake formatter. Any failure of the hook itself (no
# nix, a timeout, no repo) lets the commit through: false silence beats a
# blocked commit.
set -uo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[[ -n $cmd ]] || exit 0

# Only a real `git ... commit` statement, not the words inside a message.
dequoted=$(printf '%s' "$cmd" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")
printf '%s' "$dequoted" | grep -Eq '(^|[;&|(]|&&)[[:space:]]*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)' || exit 0

# Where the commit happens: `git -C DIR`, else a leading `cd DIR &&`, else cwd.
dir=$(printf '%s' "$dequoted" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:]]+)[[:space:]].*commit.*/\1/p' | head -1)
[[ -n $dir ]] || dir=$(printf '%s' "$dequoted" | sed -nE 's/^[[:space:]]*cd[[:space:]]+([^[:space:];&|]+).*/\1/p' | head -1)
dir=${dir/#\~/$HOME}
cd "${cwd:-.}" 2>/dev/null || exit 0
cd "${dir:-.}" 2>/dev/null || exit 0
top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$top" || exit 0
[[ -f flake.nix ]] && grep -q formatter flake.nix flake/*.nix 2>/dev/null || exit 0

# Changed files, staged or not: a `git add -A && git commit` has not staged yet
# when this runs.
mapfile -t files < <(git status --porcelain --untracked-files=all | awk '$1 != "D" {print substr($0, 4)}' | sed 's/.* -> //' | while read -r f; do [[ -f $f ]] && printf '%s\n' "$f"; done)
((${#files[@]})) || exit 0

before=$(sha256sum -- "${files[@]}" 2>/dev/null)
timeout 90 nix fmt -- "${files[@]}" >/dev/null 2>&1 || exit 0
after=$(sha256sum -- "${files[@]}" 2>/dev/null)
[[ $before == "$after" ]] && exit 0

changed=$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed -nE 's/^> [0-9a-f]+  //p' | paste -sd' ' -)
reason="nix fmt reformatted: $changed. Review the change, git add those files, and run the commit again."
jq -cn --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
