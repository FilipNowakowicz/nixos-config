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
      imv
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
    profiles."default" = {
      id = 0;
      isDefault = true;
      settings = {
        # Hardware acceleration (video decoding)
        "media.ffmpeg.vaapi.enabled" = true;
        "media.hardware-video-decoding.force-enabled" = true;
        "widget.wayland-dmabuf-vaapi.enabled" = true;
        # Comet Lake exposes VA-API decode for VP9/H.264/HEVC but not AV1;
        # avoid Firefox falling back to CPU-bound AV1 playback.
        "media.av1.enabled" = false;

        # Keep memory pressure behavior explicit; avoid legacy CPU/rendering tweaks.
        "browser.tabs.unloadOnLowMemory" = true;
        "browser.sessionstore.unload_tabs_on_low_memory" = true;
        "privacy.resistFingerprinting" = false;
      };
    };
  };

  # GTK theming
  # All shipped themes (home/theme/themes) are dark, so a dark GTK theme is the
  # correct default. If themes ever gain a light variant this could be selected
  # dynamically from config.themes._activeThemeColorscheme.background.
  gtk = {
    enable = true;
    theme = {
      name = "Adwaita-dark";
      package = pkgs.gnome-themes-extra;
    };
    iconTheme = {
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
    };
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

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      # Browser
      "text/html" = "firefox.desktop";
      "x-scheme-handler/http" = "firefox.desktop";
      "x-scheme-handler/https" = "firefox.desktop";
      "x-scheme-handler/about" = "firefox.desktop";

      # PDF (Firefox built-in viewer)
      "application/pdf" = "firefox.desktop";

      # Images
      "image/jpeg" = "imv.desktop";
      "image/png" = "imv.desktop";
      "image/gif" = "imv.desktop";
      "image/webp" = "imv.desktop";
      "image/avif" = "imv.desktop";
      "image/tiff" = "imv.desktop";
      "image/bmp" = "imv.desktop";
      "image/svg+xml" = "imv.desktop";

      # Video
      "video/mp4" = "mpv.desktop";
      "video/webm" = "mpv.desktop";
      "video/x-matroska" = "mpv.desktop";
      "video/avi" = "mpv.desktop";
      "video/quicktime" = "mpv.desktop";
      "video/x-msvideo" = "mpv.desktop";

      # Audio
      "audio/mpeg" = "mpv.desktop";
      "audio/ogg" = "mpv.desktop";
      "audio/flac" = "mpv.desktop";
      "audio/x-wav" = "mpv.desktop";
      "audio/wav" = "mpv.desktop";
      "audio/opus" = "mpv.desktop";

      # File manager
      "inode/directory" = "thunar.desktop";
    };
  };

}
