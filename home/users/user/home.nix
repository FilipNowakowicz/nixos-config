{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.fleet) hostName skipHeavyPackages;
  nixRepo = "${config.home.homeDirectory}/nix";
  privateUserJs = ../../files/firefox/private-user.js;
  langgraphPython = pkgs.python3.withPackages (
    ps: with ps; [
      langchain
      langgraph
      langgraph-cli
    ]
  );
  claudeLatest = pkgs.writeShellApplication {
    name = "claude";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''
      exec npm exec --yes --package @anthropic-ai/claude-code@latest -- claude --dangerously-skip-permissions "$@"
    '';
  };

in
{
  home.packages =
    (with pkgs; [
      claudeLatest
      lazyactions

      (writeShellApplication {
        name = "firefox-private";
        runtimeInputs = [ pkgs.firefox ];
        text = ''
          profile=$(mktemp -d)
          trap 'rm -rf "$profile"' EXIT
          cp ${privateUserJs} "$profile/user.js"
          firefox --profile "$profile" --no-remote "$@"
        '';
      })

    ])
    ++ lib.optionals (!skipHeavyPackages) (
      with pkgs;
      [
        # Workstation-only packages; keep shared base lean for servers and CI.
        nodejs
        langgraphPython
        clang-tools
        gnumake
        gcc
        yt-dlp
        ffmpeg
        antigravity-cli
        grok-cli
        opencode
        opencode-claude-auth
        gh
        steam-run
      ]
    );

  imports = [
    ./common.nix
    ./codex.nix
    ./secrets.nix
    ../../profiles/workflow-packs
    ../../desktop
  ];

  userSecrets.enable = lib.mkDefault true;

  # The active theme defaults to home/theme/active.nix inside the theme module,
  # so no explicit themes.active wiring is needed here.

  my.neovim.languages.tex = {
    enable = lib.mkDefault config.workflowPacks.latex.enable;
    grammar = lib.mkDefault config.workflowPacks.latex.enable;
  };
  my.neovim.languages.c.enable = lib.mkDefault (!skipHeavyPackages);

  gtk.gtk4.theme = null;

  programs = {
    # Home Manager owns ~/.ssh/config; VM aliases are injected via runtime
    # fragments under ~/.local/state/nixos-vms/ssh/.
    ssh = {
      enable = true;
      enableDefaultConfig = false;
      includes = [
        "${config.home.homeDirectory}/.local/state/nixos-vms/ssh/*.conf"
      ];
    };

    # ── Direnv ─────────────────────────────────────────────────────────────
    direnv = {
      enable = true;
      enableZshIntegration = true;
      nix-direnv.enable = true;
    };

    # ── Zsh ────────────────────────────────────────────────────────────────
    # Base options, plugins, and vi-mode are set in home/profiles/base.nix
    # Shared aliases and shell functions are in common.nix
    zsh = {
      shellAliases = {
        theme = "theme-switch";
        copilot = "steam-run gh copilot";
      };

      initContent = ''
        # Run `rebuild --remote` to do every build step on gcp-builder.
        rebuild() {
          if [[ "''${1:-}" == --prebuilt ]]; then
            shift
            bash ${nixRepo}/scripts/rebuild-prebuilt.sh "$@"
          elif [[ "''${1:-}" == --remote ]]; then
            shift
            bash ${nixRepo}/scripts/rebuild-remote.sh "$@"
          else
            nh os switch --hostname ${hostName} . "$@"
          fi
        }

        _theme_switch_completion() {
          local themes
          themes=($(ls ${nixRepo}/home/theme/themes | sed 's/\.nix//'))
          _describe 'themes' themes
        }
        compdef _theme_switch_completion theme-switch
      '';
    };
  };

}
