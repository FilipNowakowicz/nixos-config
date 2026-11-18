# shellcheck shell=bash
# Claude Code hook: record when a session needs the person, for the quiet shell's
# agent board. One small file per session under
# $XDG_STATE_HOME/agent-usage/claude-attention says why:
#   permission  a tool is waiting for approval  (Notification: permission_prompt)
#   question    Claude is asking something       (Notification: elicitation_dialog)
#   done        the turn finished                (Stop)
#   idle        it has waited a while for input  (Notification: idle_prompt)
# A new prompt, a tool that ran (so any approval was given) or the session's end
# clears it.
#
# Hooks run on every tool call, so clearing costs no jq. Nothing is printed:
# a UserPromptSubmit hook's output would be added to the conversation. It never
# fails, so a broken state directory cannot get in the agent's way.

input=$(cat)
state="${XDG_STATE_HOME:-$HOME/.local/state}/agent-usage/claude-attention"

[[ $input =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9-]+)\" ]] || exit 0
file="$state/${BASH_REMATCH[1]}.json"
[[ $input =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"([A-Za-z]+)\" ]] || exit 0

case ${BASH_REMATCH[1]} in
UserPromptSubmit | PostToolUse | SessionEnd)
  rm -f "$file"
  exit 0
  ;;
Stop) kind="done" ;;
Notification)
  case $(jq -r '.notification_type // empty' <<<"$input" 2>/dev/null) in
  permission_prompt) kind=permission ;;
  elicitation_dialog) kind=question ;;
  idle_prompt) kind=idle ;;
  *) exit 0 ;;
  esac
  ;;
*) exit 0 ;;
esac

# An idle reminder must not hide a question that is still open.
if [ "$kind" = idle ] && [ -e "$file" ]; then
  exit 0
fi

{
  mkdir -p "$state" &&
    jq -c --arg kind "$kind" --argjson at "$(date +%s)" \
      '{at: $at, kind: $kind, message: (.message // "")}' <<<"$input" >"$file.tmp" &&
    mv "$file.tmp" "$file"
} 2>/dev/null
exit 0
