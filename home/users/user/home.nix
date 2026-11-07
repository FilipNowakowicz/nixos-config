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

  quietShell = pkgs.callPackage ../../../packages/quiet-shell { };
  claudeLatest = pkgs.writeShellApplication {
    name = "claude";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''
      exec npm exec --yes --package @anthropic-ai/claude-code@latest -- claude --dangerously-skip-permissions "$@"
    '';
  };

in
{
  # theme-switch is provided by the theme module (home/theme/module.nix).
  home.packages =
    (with pkgs; [
      (writeShellApplication {
        name = "hypr-display-mode";
        runtimeInputs = with pkgs; [
          gnugrep
          hyprland
        ];
        text = builtins.readFile ../../files/scripts/hypr-display-mode.sh;
      })

      (writeShellApplication {
        name = "hypr-layout-cycle";
        runtimeInputs = with pkgs; [
          gnused
          hyprland
          libnotify
        ];
        text = builtins.readFile ../../files/scripts/hypr-layout-cycle.sh;
      })

      (writeShellApplication {
        name = "caffeinate";
        runtimeInputs = with pkgs; [
          systemd
          libnotify
        ];
        text = builtins.readFile ../../files/scripts/caffeinate.sh;
      })

      (writeShellApplication {
        name = "power-profile";
        runtimeInputs = with pkgs; [ power-profiles-daemon ];
        text = ''
          current=$(powerprofilesctl get)
          case "$current" in
            power-saver) next=balanced ;;
            balanced)    next=performance ;;
            performance) next=power-saver ;;
            *)           next=balanced ;;
          esac
          powerprofilesctl set "$next"
        '';
      })

      (writeShellApplication {
        name = "battery-status";
        runtimeInputs = with pkgs; [
          power-profiles-daemon
          coreutils
          findutils
        ];
        text = ''
          get_bat_icon() {
            local pct=$1
            local icons=("󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹")
            local idx=$(( pct / 10 ))
            (( idx > 9 )) && idx=9
            echo "''${icons[$idx]}"
          }

          profile=$(powerprofilesctl get 2>/dev/null || echo "balanced")

          bat_dir=$(find /sys/class/power_supply -maxdepth 1 -name 'BAT*' 2>/dev/null | head -1)
          if [[ -z "$bat_dir" ]]; then
            printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "?" "$profile" "$profile"
            exit 0
          fi

          capacity=$(cat "$bat_dir/capacity")
          status=$(cat "$bat_dir/status")

          if [[ "$status" == "Full" ]]; then
            printf '{"text":"","tooltip":"%s","class":"full"}\n' "$profile"
            exit 0
          fi

          case "$status" in
            Charging) bat_icon="󰂄" ;;
            *)        bat_icon=$(get_bat_icon "$capacity") ;;
          esac

          classes="$profile"
          (( capacity <= 15 )) && classes="$classes critical"
          (( capacity > 15 && capacity <= 30 )) && classes="$classes warning"

          tooltip="$profile · ''${capacity}% · ''${status}"
          text="''${bat_icon}  ''${capacity}%"

          printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "$text" "$tooltip" "$classes"
        '';
      })

      claudeLatest
      quietShell
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
    ../../theme/module.nix
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
        rebuild = "nh os switch --hostname ${hostName} .";
        theme = "theme-switch";
        copilot = "steam-run gh copilot";
      };

      initContent = ''
        _theme_switch_completion() {
          local themes
          themes=($(ls ${nixRepo}/home/theme/themes | sed 's/\.nix//'))
          _describe 'themes' themes
        }
        compdef _theme_switch_completion theme-switch
      '';
    };
  };

  xdg = {
    # ── Themes & Config Files ──────────────────────────────────────────────
    configFile = {
      # Kitty
      "kitty/kitty.conf".source = ../../files/kitty/kitty.conf;

      # Hyprland
      "hypr/hyprland.lua".source = ../../files/hypr/hyprland.lua;

      # Hyprlock
      "hypr/hyprlock.conf".source = ../../files/hypr/hyprlock.conf;
      "hypr/lock-status".source = lib.getExe (
        pkgs.writeShellApplication {
          name = "lock-status";
          text = builtins.readFile ../../files/hypr/lock-status.sh;
        }
      );
    };
  };

  services = {
    # ── Syncthing ──────────────────────────────────────────────────────────
    syncthing.enable = lib.mkDefault false;

    # ── Cliphist ────────────────────────────────────────────────────────────
    cliphist.enable = true;

    # ── Hypridle ───────────────────────────────────────────────────────────
    # Hyprland-native idle daemon. Single source of truth for desktop idle
    # behavior: lock at 5 minutes, screen off at 5:30, suspend at 15 minutes.
    # Uses loginctl lock-session so Hyprland's session-lock protocol handles
    # hyprlock lifecycle independently of the idle timer.
    hypridle = {
      enable = true;
      systemdTarget = "nixos-fake-graphical-session.target";
      settings = {
        general = {
          after_sleep_cmd = "hyprctl dispatch dpms on";
          before_sleep_cmd = "loginctl lock-session";
          lock_cmd = "pidof hyprlock || ${pkgs.hyprlock}/bin/hyprlock";
        };
        listener = [
          # Idle locks only: a few seconds to move the mouse and carry on
          # without a password. Manual and before-sleep locks go through
          # lock_cmd above and always ask.
          {
            timeout = 300;
            on-timeout = "pidof hyprlock > /dev/null || ${pkgs.hyprlock}/bin/hyprlock --grace 5";
          }
          {
            timeout = 330;
            on-timeout = "hyprctl dispatch dpms off";
            on-resume = "hyprctl dispatch dpms on";
          }
          {
            timeout = 900;
            on-timeout = "${pkgs.systemd}/bin/systemctl suspend";
          }
        ];
      };
    };
  };

  systemd.user.services = {
    # A unit so it heals by itself when a rebuild severs its Wayland connection.
    quiet-shell = {
      Unit = {
        Description = "Quiet desktop shell";
        After = [ "nixos-fake-graphical-session.target" ];
        PartOf = [ "nixos-fake-graphical-session.target" ];
      };
      Service = {
        ExecStart = "${quietShell}/bin/quiet-shell";
        Restart = "always";
        RestartSec = 2;
      };
      Install = {
        WantedBy = [ "nixos-fake-graphical-session.target" ];
      };
    };
  };
}
