# The Hyprland desktop: compositor config, Quiet Shell and the session services
# around them. Separate from the workstation's dev tools and secrets so a VM test
# can import exactly this (tests/nixos/desktop-session.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  quietShell = pkgs.callPackage ../../packages/quiet-shell {
    # kitty, nvim, hyprctl and theme-switch belong to the desktop, not the shell
    # package; theme-switch also calls back into the shell, so packaging it would
    # be a cycle. These directories guarantee them however the shell is started.
    extraPath = [
      "${config.home.profileDirectory}/bin"
      "/run/current-system/sw/bin"
    ];
  };
in
{
  imports = [ ../theme/module.nix ];

  home.packages = [
    (pkgs.writeShellApplication {
      name = "hypr-layout-cycle";
      runtimeInputs = with pkgs; [
        gnused
        hyprland
        libnotify
      ];
      text = builtins.readFile ../files/scripts/hypr-layout-cycle.sh;
    })

    (pkgs.writeShellApplication {
      name = "hypr-spotify-autostart";
      runtimeInputs = [ pkgs.systemd ];
      text = builtins.readFile ../files/scripts/hypr-spotify-autostart.sh;
    })

    quietShell
  ];

  xdg.configFile = {
    "kitty/kitty.conf".source = ../files/kitty/kitty.conf;
    "hypr/hyprland.lua".source = ../files/hypr/hyprland.lua;
    "hypr/hyprlock.conf".source = ../files/hypr/hyprlock.conf;
    "hypr/lock-status".source = lib.getExe (
      pkgs.writeShellApplication {
        name = "lock-status";
        text = builtins.readFile ../files/hypr/lock-status.sh;
      }
    );
  };

  services = {
    cliphist.enable = true;

    # Hyprland-native idle daemon. Single source of truth for desktop idle
    # behavior: lock at 5 minutes, screen off at 5:30, suspend at 15 minutes.
    # Uses loginctl lock-session so Hyprland's session-lock protocol handles
    # hyprlock lifecycle independently of the idle timer.
    hypridle = {
      enable = true;
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
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        Type = "dbus";
        BusName = "org.kde.StatusNotifierWatcher";
        ExecStart = "${quietShell.trayWatcher}/bin/quiet-tray-watcher";
        Restart = "always";
        RestartSec = 2;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
    quiet-shell = {
      Unit = {
        Description = "Quiet desktop shell";
        After = [
          "graphical-session.target"
          "tray-watcher.service"
        ];
        Wants = [ "tray-watcher.service" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${quietShell}/bin/quiet-shell";
        Restart = "always";
        RestartSec = 2;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
