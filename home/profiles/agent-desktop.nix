{ pkgs, lib, ... }:
let
  # PreToolUse hook: asks before desktop_request_host and before a shell runs
  # `agent-desktop host start|approve`. Nothing else Agent Desktop does prompts.
  guard = pkgs.writeShellApplication {
    name = "agent-desktop-guard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
    ];
    text = builtins.readFile ../files/agents/agent-desktop-guard.sh;
  };

  mergeSettings = pkgs.writeShellApplication {
    name = "claude-settings-agent-desktop";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = builtins.readFile ../files/agents/claude-settings-agent-desktop.sh;
  };
in
{
  # Claude Code's own permission prompt is the only approval for an agent to use
  # this screen: the hook asks, and AGENT_DESKTOP_HOST_APPROVAL=client tells
  # Agent Desktop not to ask again with a notification. Both go into
  # ~/.claude/settings.json in one write, because the variable without the hook
  # would skip the person entirely. Other clients (Codex, a CLI) do not get the
  # variable and keep Agent Desktop's notification.
  home.activation.claudeAgentDesktopHostApproval = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${lib.getExe mergeSettings} \
      "$HOME/.claude/settings.json" \
      ${lib.getExe guard} \
      ${../files/agents/claude-settings-agent-desktop.jq}
  '';
}
