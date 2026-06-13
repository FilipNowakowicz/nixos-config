#!/usr/bin/env bash
# PreToolUse guard for the Agent tool (matcher: "Agent"). Companion to
# guard-bash.sh/guard-edits.sh: warns before launching an isolation:worktree
# subagent while the primary checkout has uncommitted, non-generated changes.
#
# Background (learning candidate
# 2026-06-08-worktree-subagent-reset-clobbers-shared-checkout): worktree
# isolation gives a subagent its own working directory, but it shares this
# checkout's .git — a subagent that runs git commands (e.g. `git reset
# --hard`, `git checkout .`) against THIS checkout's path can still destroy
# staged/unstaged edits here. Untracked build byproducts (`result`,
# `result-*`) are ignored; any other uncommitted change is treated as real.
#
#   ask   — isolation:worktree spawn while this checkout has uncommitted
#           tracked changes or untracked files beyond the harmless allowlist
#   allow — everything else (no isolation:worktree, clean tree, or only
#           harmless untracked byproducts)
set -uo pipefail

field() { # $1=jq-path  $2=grep-fallback-key
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r "$1 // empty"
  else
    printf '%s' "$input" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
  fi
}

emit() { # $1=permissionDecision  $2=reason
  local reason
  reason=$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' | tr -d '\n')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$reason"
  exit 0
}

# Lines from `git status --porcelain=v1` that represent real, non-generated
# changes — i.e. everything except untracked `result`/`result-*` nix-build
# symlinks.
real_dirty_lines() {
  local repo="$1"
  git -C "$repo" status --porcelain=v1 2>/dev/null | while IFS= read -r line; do
    code="${line:0:2}"
    path="${line:3}"
    if [[ $code == '??' ]]; then
      case "$path" in
      result | result-*) continue ;;
      esac
    fi
    printf '%s\n' "$line"
  done
}

run_guard() {
  local input="$1"
  local isolation repo_dir lines count sample reason

  isolation=$(field '.tool_input.isolation' 'isolation')
  [[ $isolation == worktree ]] || return 0

  repo_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
  git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  lines=$(real_dirty_lines "$repo_dir")
  [[ -n $lines ]] || return 0

  count=$(printf '%s\n' "$lines" | grep -c .)
  sample=$(printf '%s\n' "$lines" | head -5 | sed 's/^/  /')
  reason="This checkout ($repo_dir) has $count uncommitted change(s) and you are about to launch an isolation:worktree subagent. Worktree isolation gives the subagent its own files, but it shares this checkout's .git — a subagent git command (e.g. git reset/checkout/clean) targeting this path can still destroy these edits. Commit or stash them first, or instruct the subagent in its prompt to operate ONLY inside its assigned worktree path and never run git commands against $repo_dir. Sample changes:
$sample"

  emit ask "$reason"
}

self_test() {
  local tmp repo out script
  script="${BASH_SOURCE[0]}"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  repo="$tmp/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name 'Guard Test'
  printf 'one\n' >"$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m seed

  fail() {
    echo "guard-agent-dirty-checkout: self-test: $*" >&2
    exit 1
  }

  # Clean tree, isolation:worktree -> silent allow.
  out=$(CLAUDE_PROJECT_DIR="$repo" bash "$script" <<<'{"tool_name":"Agent","tool_input":{"isolation":"worktree"}}')
  [[ -z $out ]] || fail "expected silent allow on a clean tree (got: $out)"

  # Dirty tracked file, but no worktree isolation -> silent allow.
  printf 'two\n' >"$repo/file.txt"
  out=$(CLAUDE_PROJECT_DIR="$repo" bash "$script" <<<'{"tool_name":"Agent","tool_input":{}}')
  [[ -z $out ]] || fail "expected silent allow when isolation is not 'worktree' (got: $out)"

  # Dirty tracked file + isolation:worktree -> ask.
  out=$(CLAUDE_PROJECT_DIR="$repo" bash "$script" <<<'{"tool_name":"Agent","tool_input":{"isolation":"worktree"}}')
  [[ $(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out") == ask ]] ||
    fail "expected 'ask' for a dirty checkout + isolation:worktree (got: $out)"
  [[ $(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out") == *file.txt* ]] ||
    fail "expected the dirty path to be named in the reason (got: $out)"

  # Revert, then only a harmless untracked 'result' symlink -> silent allow.
  git -C "$repo" checkout -q -- file.txt
  ln -sf /nix/store/fake-result "$repo/result"
  out=$(CLAUDE_PROJECT_DIR="$repo" bash "$script" <<<'{"tool_name":"Agent","tool_input":{"isolation":"worktree"}}')
  [[ -z $out ]] || fail "expected 'result' symlink to be treated as harmless (got: $out)"

  printf 'guard-agent-dirty-checkout self-test passed\n'
}

if [[ ${1:-} == --self-test ]]; then
  self_test
  exit 0
fi

input=$(cat)
run_guard "$input"
exit 0
