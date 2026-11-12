# The Agent Desktop host-approval hook asks only before an agent gets the
# person's screen, and its settings merge keeps everything else in place.
{
  nixpkgs,
  system,
  ...
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
  guard = pkgs.writeShellApplication {
    name = "agent-desktop-guard";
    runtimeInputs = [
      pkgs.gnugrep
      pkgs.jq
    ];
    text = builtins.readFile ../../home/files/agents/agent-desktop-guard.sh;
  };
  merge = pkgs.writeShellApplication {
    name = "claude-settings-agent-desktop";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = builtins.readFile ../../home/files/agents/claude-settings-agent-desktop.sh;
  };
  filter = ../../home/files/agents/claude-settings-agent-desktop.jq;
in
pkgs.runCommand "agent-desktop-guard-tests"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.bash
    ];
  }
  ''
    set -euo pipefail
    g=${pkgs.lib.getExe guard}
    decision() { "$g" | jq -r '.hookSpecificOutput.permissionDecision // empty'; }
    expect() { # $1=want $2=input
      got=$(printf '%s' "$2" | decision)
      [ "$got" = "$1" ] || { echo "want '$1', got '$got' for $2" >&2; exit 1; }
    }

    # Asks before an agent gets the screen, with its reason and minutes.
    expect ask '{"tool_name":"mcp__agent-desktop__desktop_request_host","tool_input":{"reason":"Open the router page","minutes":10}}'
    printf '%s' '{"tool_name":"mcp__agent-desktop__desktop_request_host","tool_input":{"reason":"Open the router page","minutes":10}}' \
      | "$g" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("10 min: Open the router page")' >/dev/null

    # Nothing else Agent Desktop does needs approval.
    for tool in desktop_create desktop_screenshot desktop_click desktop_request_human desktop_browser; do
      expect "" "{\"tool_name\":\"mcp__agent-desktop__$tool\",\"tool_input\":{}}"
    done

    # Shell commands that allow a host session without a request.
    expect ask '{"tool_name":"Bash","tool_input":{"command":"agent-desktop host start --minutes 5"}}'
    expect ask '{"tool_name":"Bash","tool_input":{"command":"cd ~/agent-desktop && uv run agent-desktop host approve"}}'
    expect ask '{"tool_name":"Bash","tool_input":{"command":"python -m agent_desktop.cli host start"}}'
    expect "" '{"tool_name":"Bash","tool_input":{"command":"agent-desktop host status"}}'
    expect "" '{"tool_name":"Bash","tool_input":{"command":"agent-desktop host stop"}}'
    expect "" '{"tool_name":"Bash","tool_input":{"command":"agent-desktop take s1"}}'
    expect "" '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
    expect "" '{"tool_name":"Edit","tool_input":{"file_path":"/x"}}'

    # The merge keeps other settings and hooks, and is idempotent.
    s=$PWD/settings.json
    cat >"$s" <<'JSON'
    {"env":{"KEEP":"1"},"model":"opus",
     "hooks":{"Stop":[{"hooks":[{"type":"command","command":"keep-awake stop"}]}],
              "PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"guard-edits"}]},
                            {"matcher":"Bash","hooks":[{"type":"command","command":"/old/agent-desktop-guard || true"}]}]}}
    JSON
    ${pkgs.lib.getExe merge} "$s" "$g" ${filter}
    ${pkgs.lib.getExe merge} "$s" "$g" ${filter}
    jq -e '
      .env == {KEEP: "1", AGENT_DESKTOP_HOST_APPROVAL: "client"}
      and .model == "opus"
      and .hooks.Stop[0].hooks[0].command == "keep-awake stop"
      and ([.hooks.PreToolUse[] | select(.matcher == "Edit")] | length) == 1
      and ([.hooks.PreToolUse[] | select(any(.hooks[]; .command | contains("agent-desktop-guard")))] | map(.matcher))
          == ["mcp__agent-desktop__desktop_request_host", "Bash"]
      and ([.hooks.PreToolUse[].hooks[].command | select(startswith("/old/"))] | length) == 0
    ' "$s" >/dev/null

    # The installed command still asks when the guard itself is gone.
    command=$(jq -r '.hooks.PreToolUse[-1].hooks[0].command' "$s" | sed "s|$g|/nix/store/missing-agent-desktop-guard|")
    [ "$(echo '{}' | bash -c "$command" 2>/dev/null | jq -r .hookSpecificOutput.permissionDecision)" = ask ]

    # A missing file is created; invalid JSON is left alone without failing.
    ${pkgs.lib.getExe merge} "$PWD/new/settings.json" "$g" ${filter}
    jq -e '.env.AGENT_DESKTOP_HOST_APPROVAL == "client"' new/settings.json >/dev/null
    printf 'not json' >bad.json
    ${pkgs.lib.getExe merge} "$PWD/bad.json" "$g" ${filter} 2>/dev/null
    [ "$(cat bad.json)" = "not json" ]

    touch $out
  ''
