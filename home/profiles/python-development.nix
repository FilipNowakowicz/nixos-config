{ pkgs, ... }:
let
  globalAgentInstructions = pkgs.writeText "global-agent-instructions.md" (
    builtins.readFile ../files/agents/global-development.md
  );
in
{
  home = {
    packages = [ pkgs.uv ];

    # These are the supported user-global instruction surfaces for the three
    # agent CLIs installed on main. One source keeps their Python workflow and
    # personal Git preferences identical across every repository.
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
