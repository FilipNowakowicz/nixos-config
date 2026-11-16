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
in
{
  # Claude Code writes ~/.claude/settings.json itself, so Home Manager cannot own
  # it; set just the status line in place and keep everything else.
  home.activation.claudeStatusLine = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    settings="$HOME/.claude/settings.json"
    mkdir -p "$(dirname "$settings")"
    [ -s "$settings" ] || printf '{}\n' >"$settings"
    tmp=$(mktemp "$settings.XXXXXX")
    if ${lib.getExe pkgs.jq} --arg command ${lib.getExe statusline} \
      '.statusLine = {type: "command", command: $command}' "$settings" >"$tmp"; then
      chmod --reference="$settings" "$tmp"
      run mv "$tmp" "$settings"
    else
      rm -f "$tmp"
      echo "claude-statusline: $settings is not valid JSON; status line not set" >&2
    fi
  '';
}
