{ pkgs, lib, ... }:
let
  globalAgentInstructions = pkgs.writeText "global-agent-instructions.md" (
    builtins.readFile ../files/agents/global-development.md
  );
  pythonShim =
    name:
    pkgs.writeShellScriptBin name ''
      exec ${lib.getExe pkgs.uv} run --no-project --quiet python "$@"
    '';
in
{
  home = {
    # `python3` and `python` on PATH run uv's managed interpreter (the 3.12 pin
    # below), not a Nix Python. Agents reach for `python3 - <<EOF` for quick
    # edits and checks, and `#!/usr/bin/env python3` scripts need it; without
    # these they failed with "command not found" in a bare shell. Projects still
    # use `uv run` for their own environment; a dev shell's python3 comes first.
    packages = [
      pkgs.uv
    ]
    ++ map pythonShim [
      "python3"
      "python"
    ];

    # These are the supported user-global instruction surfaces for the three
    # agent CLIs installed on main. One source keeps their Python workflow,
    # worktree layout, and personal Git preferences identical across every repository.
    file = {
      ".claude/CLAUDE.md" = {
        force = true;
        source = globalAgentInstructions;
      };
      ".codex/AGENTS.md" = {
        force = true;
        source = globalAgentInstructions;
      };
      ".gemini/GEMINI.md" = {
        force = true;
        source = globalAgentInstructions;
      };
    };
  };

  # The commit rule above is only an instruction, and the nix repo's
  # commit-msg hook only strips trailers there. Turn Claude Code's own
  # commit/PR attribution off so every repository starts clean. Claude Code
  # writes ~/.claude/settings.json itself, so set just this key in place.
  home.activation.claudeNoAttribution = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    settings="$HOME/.claude/settings.json"
    mkdir -p "$(dirname "$settings")"
    [ -s "$settings" ] || printf '{}\n' >"$settings"
    tmp=$(mktemp "$settings.XXXXXX")
    if ${lib.getExe pkgs.jq} '.attribution = {commit: "", pr: ""}' "$settings" >"$tmp"; then
      chmod --reference="$settings" "$tmp"
      run mv "$tmp" "$settings"
    else
      rm -f "$tmp"
      echo "claude-attribution: $settings is not valid JSON; attribution not disabled" >&2
    fi
  '';

  xdg.configFile = {
    "uv/uv.toml".text = ''
      # Avoid the Nix profile's incidental Python executable. uv-managed
      # interpreters run through main's centrally configured nix-ld support.
      python-preference = "only-managed"
    '';

    # uv treats this as the user-global pin when a project has no closer
    # .python-version. 3.12 is the conservative scientific-Python default;
    # repositories remain free to declare another supported version.
    "uv/.python-version".text = ''
      3.12
    '';
  };
}
