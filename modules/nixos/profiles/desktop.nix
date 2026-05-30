{ pkgs, ... }:
{
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
  users.users.user.extraGroups = [ "input" ];

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
}
