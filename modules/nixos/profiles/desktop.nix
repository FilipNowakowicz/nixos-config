{ pkgs, ... }:
{
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

      # Provide a native Secret Service for applications such as Python
      # keyring.  The service module installs the capability wrapper and
      # D-Bus activation files; greetd's PAM hook initializes and unlocks the
      # login collection when the desktop session is entered with a password.
      gnome.gnome-keyring.enable = true;
    };

    security.pam.services.greetd.enableGnomeKeyring = true;

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
