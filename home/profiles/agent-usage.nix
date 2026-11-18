{ pkgs, lib, ... }:
let
  # Claude Code gives its usage limits only to the status line command, so the
  # status line also records them (and each running session) under
  # ~/.local/state/agent-usage for the quiet shell's agents card. Codex writes its
  # limits into its own session logs, which the card reads directly.
  statusline = pkgs.writeShellApplication {
    name = "claude-statusline";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.jq
    ];
    # The status line must print even when a step fails.
    bashOptions = [ ];
    text = builtins.readFile ../files/agents/claude-statusline.sh;
  };
  # Notes when a session waits on the person (a permission prompt, a question, a
  # finished turn) for the quiet shell's agent board, and clears it once it moves.
  attention = pkgs.writeShellApplication {
    name = "claude-attention";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    # A hook must never fail the agent's turn.
    bashOptions = [ ];
    text = builtins.readFile ../files/agents/claude-attention.sh;
  };
  # Earlier copies of the attention hook are replaced, so activation is idempotent;
  # every other hook is kept.
  settingsFilter = pkgs.writeText "claude-usage-settings.jq" ''
    def ours: any((.hooks // [])[]; (.command // "") | contains("claude-attention"));
    .statusLine = {type: "command", command: $statusline}
    | .hooks = (.hooks // {})
    | reduce ("Notification", "Stop", "UserPromptSubmit", "PostToolUse", "SessionEnd") as $event (.;
        .hooks[$event] = (
          [(.hooks[$event] // [])[] | select(ours | not)]
          + [{hooks: [{type: "command", command: $attention}]}]
        ))
  '';
in
{
  # Claude Code writes ~/.claude/settings.json itself, so Home Manager cannot own
  # it; set just the status line and the attention hooks in place and keep
  # everything else.
  home.activation.claudeStatusLine = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    settings="$HOME/.claude/settings.json"
    mkdir -p "$(dirname "$settings")"
    [ -s "$settings" ] || printf '{}\n' >"$settings"
    tmp=$(mktemp "$settings.XXXXXX")
    if ${lib.getExe pkgs.jq} --arg statusline ${lib.getExe statusline} \
      --arg attention ${lib.getExe attention} \
      -f ${settingsFilter} "$settings" >"$tmp"; then
      chmod --reference="$settings" "$tmp"
      run mv "$tmp" "$settings"
    else
      rm -f "$tmp"
      echo "claude-statusline: $settings is not valid JSON; status line and hooks not set" >&2
    fi
  '';
}
