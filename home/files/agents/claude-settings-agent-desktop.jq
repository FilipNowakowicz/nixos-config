# Merge the Agent Desktop host-approval hook into ~/.claude/settings.json.
#
# The hook and AGENT_DESKTOP_HOST_APPROVAL=client are written together, in one
# file, because the variable without the hook would let an agent use the screen
# without asking. Settings env reaches the MCP servers Claude Code starts.
# Earlier copies of the hook (any command naming agent-desktop-guard) are
# replaced, so activation is idempotent; everything else is kept.
#
# $guard: absolute path of the guard script.

def ours: any((.hooks // [])[]; (.command // "") | contains("agent-desktop-guard"));

# If the guard is missing or fails, ask anyway: a hook that errors does not stop
# the tool call, and the variable would then skip the person's approval.
($guard + " || printf '%s\\n' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"agent-desktop-guard is missing or failed\"}}'") as $command
| .env = ((.env // {}) + {AGENT_DESKTOP_HOST_APPROVAL: "client"})
| .hooks = (.hooks // {})
| .hooks.PreToolUse = (
    [(.hooks.PreToolUse // [])[] | select(ours | not)]
    + [
      {matcher: "mcp__agent-desktop__desktop_request_host", hooks: [{type: "command", command: $command}]},
      {matcher: "Bash", hooks: [{type: "command", command: $command}]}
    ]
  )
