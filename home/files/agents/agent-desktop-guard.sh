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
# tripwire for running `agent-desktop host start|approve`, which allow a host
# session without a request; it is not a sandbox. Only a command that runs it
# asks: text that merely mentions it (quoted strings, heredoc bodies such as a
# commit message or PR body, `grep`, `echo`) does not, so a prompt means an
# agent is about to act on the person's screen.

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
  # Drop heredoc bodies and quoted strings, split into simple commands, and look
  # for one that starts with the host command, after optional variable
  # assignments, env/sudo/nohup/exec/command/time, `uv ... run` or `python -m`.
  if printf '%s\n' "$command" |
    awk '
      body { if ($0 ~ "^[[:space:]]*" delim "[[:space:]]*$") body = 0; next }
      match($0, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*/) {
        delim = substr($0, RSTART, RLENGTH)
        sub(/^<<-?[[:space:]]*["\047]?/, "", delim)
        body = 1
      }
      { print }' |
    sed -E "s/'[^']*'//g; s/\"([^\"\\\\]|\\\\.)*\"//g" |
    tr ';&|()`' '\n' |
    grep -Eq '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*((env|sudo|nohup|exec|command|time)[[:space:]]+)*(uv([[:space:]]+[^[:space:]]+)*[[:space:]]+run[[:space:]]+)?(python3?[[:space:]]+-m[[:space:]]+agent_desktop\.cli|([^[:space:]]*/)?agent-desktop)[[:space:]]+host[[:space:]]+(start|approve)([[:space:]]|$)'; then
    ask "This command lets an agent use your screen without a request: $command"
  fi
  ;;
esac
