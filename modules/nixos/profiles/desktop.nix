{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.profiles.desktop;
in
{
  options.profiles.desktop.user = lib.mkOption {
    type = lib.types.str;
    default = "user";
    description = ''
      Name of the primary interactive user account to grant
      desktop-specific group memberships (e.g. `/dev/input` access for
      swayosd-server's libinput backend). Adopters whose primary user is
      not named `user` must set this to match.
    '';
  };

  config = {
    # ── Compositor & Wayland ───────────────────────────────────────────────
    programs = {
      hyprland.enable = true;
      dconf.enable = true;
      command-not-found.enable = false;
      nix-index = {
        enable = true;
        enableZshIntegration = true;
      };
    };

    # swayosd-server needs /dev/input access for its libinput backend
    users.users.${cfg.user}.extraGroups = [ "input" ];

    services = {
      # ── Keyboard ──────────────────────────────────────────────────────────
      keyd = {
        enable = true;
        keyboards.default = {
          ids = [ "*" ];
          settings.main.capslock = "backslash";
        };
      };

      # ── Audio ──────────────────────────────────────────────────────────────
      pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
      };
      pulseaudio.enable = false;

      # ── Display Manager ────────────────────────────────────────────────────
      greetd = {
        enable = true;
        settings = {
          default_session = {
            command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd ${pkgs.hyprland}/bin/start-hyprland";
            user = "greeter";
          };
        };
      };
    };

    # Kill memory-pressure offenders in userspace before the interactive machine
    # reaches a kernel OOM or becomes too wedged to recover.
    systemd.oomd = {
      enable = true;
      enableSystemSlice = true;
      enableUserSlices = true;
    };

    # ── XDG Portals ────────────────────────────────────────────────────────
    xdg.portal = {
      enable = true;
      extraPortals = with pkgs; [
        xdg-desktop-portal-hyprland
        xdg-desktop-portal-gtk
      ];
      config.common = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.Screenshot" = [ "hyprland" ];
        "org.freedesktop.impl.portal.ScreenCast" = [ "hyprland" ];
        "org.freedesktop.impl.portal.RemoteDesktop" = [ "hyprland" ];
        "org.freedesktop.impl.portal.GlobalShortcuts" = [ "hyprland" ];
      };
    };

    # ── System Packages ────────────────────────────────────────────────────
    environment.systemPackages = with pkgs; [
      gnome-keyring
      networkmanagerapplet
      polkit_gnome
      gnome-themes-extra
    ];

    # ── Fonts ──────────────────────────────────────────────────────────────
    # `enableDefaultPackages` already pulls dejavu_fonts, liberation_ttf, and
    # noto-fonts-color-emoji; only list additions here.
    fonts = {
      enableDefaultPackages = true;
      fontDir.enable = true;
      packages = with pkgs; [
        noto-fonts
        nerd-fonts.jetbrains-mono
        inter
      ];
    };
  };
}
