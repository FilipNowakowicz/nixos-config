{
  config,
  lib,
  pkgs,
  hostName ? "main",
  skipHeavyPackages ? false,
  ...
}:
let
  nixRepo = "${config.home.homeDirectory}/nix";
  privateUserJs = ../../files/firefox/private-user.js;
  langgraphPython = pkgs.python3.withPackages (
    ps: with ps; [
      langchain
      langgraph
      langgraph-cli
    ]
  );

  launcher =
    let
      python = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);
      src = pkgs.writeText "launcher.py" (builtins.readFile ../../files/scripts/launcher.py);
    in
    pkgs.stdenv.mkDerivation {
      name = "launcher";
      dontUnpack = true;

      nativeBuildInputs = with pkgs; [
        gobject-introspection
        wrapGAppsHook4
      ];

      buildInputs = with pkgs; [
        glib
        pango
        gdk-pixbuf
        graphene
        harfbuzz
        gtk4
        gtk4-layer-shell
      ];

      installPhase = ''
        mkdir -p $out/bin $out/libexec
        cp ${src} $out/libexec/launcher.py
        cat > $out/bin/launcher <<EOF
        #!${pkgs.bash}/bin/sh
        exec ${python}/bin/python3 $out/libexec/launcher.py "\$@"
        EOF
        chmod +x $out/bin/launcher
      '';

      preFixup = ''
        gappsWrapperArgs+=(
          --set GDK_BACKEND wayland
          --set GTK4_LAYER_SHELL_LIB "${pkgs.gtk4-layer-shell}/lib/libgtk4-layer-shell.so.0"
        )
      '';
    };

  controlCenter = pkgs.callPackage ../../../packages/control-center { };
  waybarStyle =
    lib.replaceStrings
      [ ''@import "colors.css";'' ]
      [ ''@import url("file://${config.xdg.configHome}/waybar/colors.css");'' ]
      (builtins.readFile ../../files/waybar/style.css);

  batteryNotify = pkgs.writeShellApplication {
    name = "battery-notify";
    runtimeInputs = with pkgs; [
      libnotify
      coreutils
      findutils
    ];
    text = ''
      STATE_FILE="''${XDG_RUNTIME_DIR:-/tmp}/battery-notify-level"

      bat_dir=$(find /sys/class/power_supply -maxdepth 1 -name 'BAT*' 2>/dev/null | head -1)
      [[ -z "$bat_dir" ]] && exit 0

      capacity=$(cat "$bat_dir/capacity")
      status=$(cat "$bat_dir/status")

      # Clear state and exit when on AC power
      [[ "$status" == "Charging" || "$status" == "Full" ]] && { rm -f "$STATE_FILE"; exit 0; }

      if (( capacity <= 5 )); then
        level="critical"
      elif (( capacity <= 15 )); then
        level="warning-low"
      elif (( capacity <= 30 )); then
        level="warning"
      else
        level="ok"
      fi

      prev_level=$(cat "$STATE_FILE" 2>/dev/null || echo "ok")
      [[ "$level" == "$prev_level" ]] && exit 0

      case "$level" in
        critical)
          notify-send -u critical -i battery-caution "Battery Critical" "''${capacity}% — plug in now"
          ;;
        warning-low)
          notify-send -u critical -i battery-low "Battery Low" "''${capacity}% remaining"
          ;;
        warning)
          notify-send -u normal -i battery-low "Battery Warning" "''${capacity}% remaining"
          ;;
        ok) ;;
      esac

      echo "$level" > "$STATE_FILE"
    '';
  };

  codexLatest = pkgs.writeShellApplication {
    name = "codex";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''
      exec npm exec --yes --package @openai/codex@latest -- codex --dangerously-bypass-approvals-and-sandbox "$@"
    '';
  };

  claudeLatest = pkgs.writeShellApplication {
    name = "claude";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''
      exec npm exec --yes --package @anthropic-ai/claude-code@latest -- claude --dangerously-skip-permissions "$@"
    '';
  };

  waybarAnchor =
    let
      python = pkgs.python3;
      src = pkgs.writeText "waybar-anchor.py" (builtins.readFile ../../files/scripts/waybar-anchor.py);
      runtimePath = lib.makeBinPath (
        with pkgs;
        [
          mako
          wireplumber
        ]
      );
    in
    pkgs.writeShellScriptBin "waybar-anchor" ''
      export PATH="${runtimePath}:$PATH"
      exec ${python}/bin/python3 ${src} "$@"
    '';
in
{
  # theme-switch is provided by the theme module (home/theme/module.nix).
  home.packages =
    (with pkgs; [
      (writeShellApplication {
        name = "waybar-weather";
        runtimeInputs = with pkgs; [ curl ];
        text = builtins.readFile ../../files/scripts/waybar-weather.sh;
      })

      (writeShellApplication {
        name = "waybar-toggle";
        runtimeInputs = with pkgs; [
          hyprland
          procps
          gnugrep
        ];
        text = builtins.readFile ../../files/scripts/waybar-toggle.sh;
      })

      (writeShellApplication {
        name = "hypr-display-mode";
        runtimeInputs = with pkgs; [
          gnugrep
          hyprland
        ];
        text = builtins.readFile ../../files/scripts/hypr-display-mode.sh;
      })

      waybarAnchor

      controlCenter

      (writeShellApplication {
        name = "clipboard-pick";
        runtimeInputs = with pkgs; [
          cliphist
          fzf
          wl-clipboard
        ];
        text = builtins.readFile ../../files/scripts/clipboard-pick.sh;
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

      batteryNotify
      codexLatest
      claudeLatest
      launcher
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
        gemini-cli
        grok-cli
        opencode
        opencode-claude-auth
        gh
        steam-run
      ]
    );

  imports = [
    ./common.nix
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
        cb = "clipboard-pick";
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
      "hypr/hyprland.conf".source = ../../files/hypr/hyprland.conf;

      # Hyprlock
      "hypr/hyprlock.conf".source = ../../files/hypr/hyprlock.conf;

      # Waybar
      "waybar/config".source = ../../files/waybar/config;
      "waybar/style.css".text = waybarStyle;
    };
  };

  services = {
    # ── Syncthing ──────────────────────────────────────────────────────────
    syncthing.enable = lib.mkDefault false;

    # ── Cliphist ────────────────────────────────────────────────────────────
    cliphist.enable = true;

    # ── Mako ───────────────────────────────────────────────────────────────
    # Config is managed by home/theme/module.nix (per-theme mako-config file,
    # symlinked at ~/.config/mako/config) so runtime theme-switch works without
    # a rebuild. Do not manage mako config here to avoid conflicts.
    mako.enable = true;

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
          {
            timeout = 300;
            on-timeout = "pidof hyprlock > /dev/null || ${pkgs.hyprlock}/bin/hyprlock";
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
    battery-notify = {
      Unit = {
        Description = "Battery low notification check";
        After = [ "nixos-fake-graphical-session.target" ];
        PartOf = [ "nixos-fake-graphical-session.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${batteryNotify}/bin/battery-notify";
      };
      Install = {
        WantedBy = [ "nixos-fake-graphical-session.target" ];
      };
    };

  };

  systemd.user.timers.battery-notify = {
    Unit.Description = "Poll battery level every minute";
    Timer = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
