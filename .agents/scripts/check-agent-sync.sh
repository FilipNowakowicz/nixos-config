#!/usr/bin/env bash
# Keep Claude Code and Codex on the same shared agent surface.
#
# - Every repo hook wired for Claude is wired for Codex too, unless it guards a
#   Claude-only tool (listed below).
# - Every hook script in .claude/hooks/ is wired somewhere.
# - Claude sees the shared skills through the .claude/skills symlink.
# - Each shared skill has the frontmatter both agents need to discover it.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
rc=0
fail() {
  printf 'check-agent-sync: %s\n' "$*" >&2
  rc=1
}

# Hooks for tools Codex does not have (Claude's Agent tool).
claude_only='guard-agent-dirty-checkout.sh'

hooks_in() { jq -r '.. | .command? // empty' "$1" | grep -oE '\.claude/hooks/[A-Za-z0-9_.-]+' | sort -u; }
claude=$(hooks_in .claude/settings.json)
codex=$(hooks_in .codex/hooks.json)

for hook in $claude; do
  [[ $hook == *"$claude_only" ]] && continue
  grep -qxF "$hook" <<<"$codex" || fail "$hook is wired in .claude/settings.json but not .codex/hooks.json"
done
for hook in $codex; do
  grep -qxF "$hook" <<<"$claude" || fail "$hook is wired in .codex/hooks.json but not .claude/settings.json"
done
for script in .claude/hooks/*.sh; do
  grep -qxF "$script" <<<"$claude"$'\n'"$codex" || fail "$script is not wired in either agent"
done

[[ $(readlink .claude/skills) == ../.agents/skills ]] || fail ".claude/skills must be a symlink to ../.agents/skills"

for skill in .agents/skills/*/; do
  f=$skill/SKILL.md
  name=${skill%/}
  name=${name##*/}
  [[ -f $f ]] || {
    fail "$skill has no SKILL.md"
    continue
  }
  grep -qx "name: $name" "$f" || fail "$f: frontmatter name must be $name"
  grep -q '^description: .\{20,\}' "$f" || fail "$f: needs a description line for discovery"
done

exit "$rc"
