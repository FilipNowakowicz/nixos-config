{
  pkgs,
  config,
  skipHeavyPackages ? false,
  enableSpotify ? true,
  ...
}:
{
  home.packages =
    with pkgs;
    [
      # ── Terminal ────────────────────────────────────────────────────────────
      kitty

      # ── Wayland utilities ──────────────────────────────────────────────────
      wl-clipboard
      grim # screenshot
      slurp # region select (used with grim)
      waybar
      swaybg
      hyprlock
      brightnessctl
      cliphist
      swayosd
      wlsunset

      # ── Desktop UX ─────────────────────────────────────────────────────────
      pavucontrol
      blueman
      thunar
      tumbler

      # ── Browsers / Apps ────────────────────────────────────────────────────
      discord
      keepassxc
      mpv
      blanket
    ]
    ++ (if skipHeavyPackages || !enableSpotify then [ ] else [ spotify ])
    ++ [
      # ── Visuals / Toys ─────────────────────────────────────────────────────
      cava
      fastfetch
      pipes-rs
      tty-clock
      cbonsai
      cmatrix
    ];

  programs.yazi = {
    enable = true;
    shellWrapperName = "y";
    enableZshIntegration = true;
  };

  # Firefox with VA-API hardware video decoding (Intel iGPU on Wayland)
  programs.firefox = {
    enable = true;
    configPath = "${config.xdg.configHome}/mozilla/firefox";
    profiles."ivx1ayzq.default" = {
      id = 0;
      isDefault = true;
      settings = {
        # Hardware acceleration (video decoding)
        "media.ffmpeg.vaapi.enabled" = true;
        "media.hardware-video-decoding.force-enabled" = true;
        "widget.wayland-dmabuf-vaapi.enabled" = true;

        # Keep memory pressure behavior explicit; avoid legacy CPU/rendering tweaks.
        "browser.tabs.unloadOnLowMemory" = true;
        "browser.sessionstore.unload_tabs_on_low_memory" = true;
        "privacy.resistFingerprinting" = false;
      };
    };
  };

  # GTK theming
  gtk = {
    enable = true;
    gtk3.extraConfig.gtk-application-prefer-dark-theme = true;
    gtk4.extraConfig.gtk-application-prefer-dark-theme = true;
  };

  # XDG color-scheme preference (read by GTK4, libadwaita, portals)
  dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";

  # Cursor
  home.pointerCursor = {
    gtk.enable = true;
    name = "Bibata-Modern-Classic";
    package = pkgs.bibata-cursors;
    size = 24;
  };

}
