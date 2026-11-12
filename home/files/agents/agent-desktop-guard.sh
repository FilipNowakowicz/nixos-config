# shellcheck shell=bash
# Claude Code PreToolUse hook: ask before an agent gets the person's own screen.
#
# Agent Desktop starts a host session as soon as desktop_request_host runs when
# AGENT_DESKTOP_HOST_APPROVAL=client (set next to this hook in
# ~/.claude/settings.json), so this prompt is the only approval. Claude Code
# honours "ask" even with permission prompts bypassed, and the prompt can be
# answered wherever the session is followed.
#
# Nothing else is matched: private sessions, screenshots, input and sign-in
# handoffs (desktop_request_human) need no approval. The Bash case is a
# tripwire for `agent-desktop host start|approve`, which allow a host session
# without a request; it is not a sandbox.

input=$(cat)
tool=$(jq -r '.tool_name // ""' <<<"$input")

ask() {
  jq -n --arg reason "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $reason}}'
  exit 0
}

case "$tool" in
mcp__agent-desktop__desktop_request_host)
  reason=$(jq -r '.tool_input.reason // "no reason given"' <<<"$input")
  minutes=$(jq -r '.tool_input.minutes // 15' <<<"$input")
  ask "An agent asks to use your screen for $minutes min: $reason"
  ;;
Bash)
  command=$(jq -r '.tool_input.command // ""' <<<"$input")
  if grep -Eq 'agent[-_]desktop[^[:space:]]*[[:space:]]+host[[:space:]]+(start|approve)' <<<"$command"; then
    ask "This command lets an agent use your screen without a request: $command"
  fi
  ;;
esac
