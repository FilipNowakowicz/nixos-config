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
        name = "hypr-spotify-autostart";
        runtimeInputs = [ pkgs.systemd ];
        text = builtins.readFile ../../files/scripts/hypr-spotify-autostart.sh;
      })

      (writeShellApplication {
        name = "caffeinate";
        runtimeInputs = with pkgs; [
          systemd
          libnotify
        ];
        text = builtins.readFile ../../files/scripts/caffeinate.sh;
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

  # The shell's notes file (SUPER+SHIFT+N). Created empty if missing, never
  # overwritten; the restic backup lists it and would warn if it were absent.
  systemd.user.tmpfiles.rules = [
    "d %h/.local/share/quiet-shell 0700 - - -"
    "f %h/.local/share/quiet-shell/notes.md 0600 - - -"
  ];

  # Brings the notes along from ~/notes.md, their old home. Runs at the switch that
  # changes the path, so the file and the shell move together. An empty new file is
  # only the tmpfiles placeholder; real notes there are never overwritten.
  home.activation.moveNotesOutOfHome = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    old="$HOME/notes.md"
    new="${config.xdg.dataHome}/quiet-shell/notes.md"
    if [[ -f $old && ! -L $old ]]; then
      if [[ -s $new ]]; then
        warnEcho "Not moving $old: $new already has notes. Merge them by hand."
      else
        run mkdir -p "$(dirname "$new")"
        run mv -f "$old" "$new"
      fi
    fi
  '';

  systemd.user.services = {
    # A unit so it heals by itself when a rebuild severs its Wayland connection.
    # Holds the tray's registry so it outlives shell restarts; Spotify aborted
    # whenever the registry vanished with the shell.
    tray-watcher = {
      Unit = {
        Description = "Tray icon registry";
        After = [ "nixos-fake-graphical-session.target" ];
        PartOf = [ "nixos-fake-graphical-session.target" ];
      };
      Service = {
        Type = "dbus";
        BusName = "org.kde.StatusNotifierWatcher";
        ExecStart = "${quietShell.trayWatcher}/bin/quiet-tray-watcher";
        Restart = "always";
        RestartSec = 2;
      };
      Install = {
        WantedBy = [ "nixos-fake-graphical-session.target" ];
      };
    };
    quiet-shell = {
      Unit = {
        Description = "Quiet desktop shell";
        After = [
          "nixos-fake-graphical-session.target"
          "tray-watcher.service"
        ];
        Wants = [ "tray-watcher.service" ];
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
