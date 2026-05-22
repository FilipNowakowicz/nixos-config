{ config, lib, ... }:
let
  cfg = config.themes;

  # Directory where themes are stored
  themeDir = ./.;
  themesDir = themeDir + /themes;

  # Auto-discover all theme files
  themeFiles = builtins.readDir themesDir;

  # Load and validate each theme
  allThemes = lib.mapAttrs' (
    name: _:
    let
      themePath = themesDir + "/${name}";
      theme = import themePath;
      themeName = lib.removeSuffix ".nix" name;
    in
    lib.nameValuePair themeName (theme // { name = themeName; })
  ) (lib.filterAttrs (n: v: v == "regular" && lib.hasSuffix ".nix" n) themeFiles);

  # Filter: only enabled themes with existing wallpapers
  validThemes = lib.filterAttrs (
    _: theme:
    let
      enabled = theme.enabled or true;
      wallpaperExists = builtins.pathExists theme.wallpaper;
    in
    enabled && wallpaperExists
  ) allThemes;

  # Get the active theme
  activeTheme = validThemes.${cfg.active} or (lib.head (lib.attrValues validThemes));
  runtimeActiveThemeFile = "${config.home.homeDirectory}/nix/home/theme/active.nix";

  themeLinkTargets = [
    {
      source = "kitty-theme.conf";
      target = "${config.xdg.configHome}/kitty/current-theme.conf";
    }
    {
      source = "hypr-colors.conf";
      target = "${config.xdg.configHome}/hypr/colors.conf";
    }
    {
      source = "hyprlock-colors.conf";
      target = "${config.xdg.configHome}/hypr/hyprlock-colors.conf";
    }
    {
      source = "mako-config";
      target = "${config.xdg.configHome}/mako/config";
    }
    {
      source = "wallpaper";
      target = "${config.home.homeDirectory}/.local/share/wallpapers/current.png";
    }
  ];

  mkThemeLinkCommands =
    themeDirExpr:
    lib.concatMapStringsSep "\n" (link: ''
      mkdir -p ${lib.escapeShellArg (builtins.dirOf link.target)}
      ln -sf "${themeDirExpr}/${link.source}" ${lib.escapeShellArg link.target}
    '') themeLinkTargets;

  themeLinksSnippet = ''
        link_theme_assets() {
          local theme_dir="$1"
          if [[ -z "$theme_dir" ]]; then
            echo "link_theme_assets: missing theme directory" >&2
            return 1
          fi
    ${mkThemeLinkCommands "$theme_dir"}

          mkdir -p ${lib.escapeShellArg (builtins.dirOf "${config.xdg.configHome}/waybar/colors.css")}
          rm -f ${lib.escapeShellArg "${config.xdg.configHome}/waybar/colors.css"}
          install -m 0644 "$theme_dir/waybar-colors.css" ${lib.escapeShellArg "${config.xdg.configHome}/waybar/colors.css"}
        }
  '';

  # Helper to generate theme config text
  mkThemeConfig = themeName: theme: {
    # Kitty theme
    "themes/${themeName}/kitty-theme.conf".text = ''
      # vim:ft=kitty
      ## name: ${themeName}

      foreground           #${theme.colors.text}
      background           #${theme.colors.bg}
      selection_foreground #${theme.colors.text}
      selection_background #${theme.colors.brown}

      cursor            #${theme.colors.amber}
      cursor_text_color #${theme.colors.bg}

      url_color #${theme.colors.amber}

      active_border_color   #${theme.colors.amber}
      inactive_border_color #${theme.colors.brown}
      bell_border_color     #${theme.colors.orange}

      wayland_titlebar_color #${theme.colors.bg}

      active_tab_foreground   #${theme.colors.text}
      active_tab_background   #${theme.colors.bg}
      inactive_tab_foreground #${theme.colors.brown}
      inactive_tab_background #${theme.colors.bg}
      tab_bar_background      #${theme.colors.bg}

      # 16 colors — extended palette
      color0  #${theme.colors.bg}
      color8  #${theme.colors.brown}
      color1  #cc241d
      color9  #fb4934
      color2  #98971a
      color10 #b8bb26
      color3  #${theme.colors.amber}
      color11 #fabd2f
      color4  #458588
      color12 #83a598
      color5  #b16286
      color13 #d3869b
      color6  #689d6a
      color14 #8ec07c
      color7  #${theme.colors.text}
      color15 #fbf1c7
    '';

    # Hyprland colors
    "themes/${themeName}/hypr-colors.conf".text = ''
      $col_active   = rgb(${theme.colors.amber})
      $col_inactive = rgb(${theme.colors.brown})
      $col_shadow   = rgba(${theme.colors.bg}cc)
    '';

    # Hyprlock colors
    "themes/${themeName}/hyprlock-colors.conf".text = ''
      $text   = rgb(${theme.colors.text})
      $bg     = rgb(${theme.colors.bg})
      $amber  = rgb(${theme.colors.amber})
      $orange = rgb(${theme.colors.orange})
    '';

    # Waybar colors
    "themes/${themeName}/waybar-colors.css".text = ''
      @define-color bg #${theme.colors.bg};
      @define-color brown #${theme.colors.brown};
      @define-color orange #${theme.colors.orange};
      @define-color amber #${theme.colors.amber};
      @define-color text #${theme.colors.text};
    '';

    # Mako notification colors
    "themes/${themeName}/mako-config".text = ''
      font=JetBrainsMono Nerd Font 11
      background-color=#${theme.colors.bg}
      text-color=#${theme.colors.text}
      border-color=#${theme.colors.orange}
      border-radius=8
      border-size=2
      anchor=top-right
      margin=12
      padding=10,14
      width=300
      default-timeout=5000
      max-visible=5

      [mode=do-not-disturb]
      invisible=1
    '';

    # Wallpaper symlink
    "themes/${themeName}/wallpaper".source = theme.wallpaper;
  };

  # Generate configs for all valid themes
  themeConfigs = lib.foldl (
    acc: themeName: acc // (mkThemeConfig themeName validThemes.${themeName})
  ) { } (builtins.attrNames validThemes);

in
{
  options.themes = {
    active = lib.mkOption {
      type = lib.types.str;
      default = "mono-mesh";
      description = ''
        Name of the active theme. Must match a .nix filename under home/theme/themes/
        (without the .nix extension). Theme assets are symlinked into XDG config
        paths for Kitty, Hyprland, Waybar, and Mako on every rebuild.
      '';
      example = "mono-mesh";
    };
    _activeThemeColors = lib.mkOption {
      type = lib.types.attrs;
      internal = true;
      description = "Color palette of the active theme, exposed for other modules to consume (e.g. generated configs).";
    };
  };

  config = {
    themes._activeThemeColors = activeTheme.colors;
    xdg.configFile = themeConfigs // {
      "themes/links.sh".text = themeLinksSnippet;
    };

    # Symlink active theme configs into live app paths on every activation.
    # Read active.nix at activation time so a runtime theme-switch survives a
    # reboot even when the Home Manager generation was built with another theme.
    home.activation.linkActiveTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      . "${config.xdg.configHome}/themes/links.sh"

      active_theme="${activeTheme.name}"
      active_file=${lib.escapeShellArg runtimeActiveThemeFile}
      if [[ -f "$active_file" ]]; then
        runtime_theme=$(sed -n 's|.*themes/\([a-z0-9-]\+\)\.nix.*|\1|p' "$active_file" | head -n1)
        if [[ -n "$runtime_theme" && -d "${config.xdg.configHome}/themes/$runtime_theme" ]]; then
          active_theme="$runtime_theme"
        fi
      fi

      link_theme_assets "${config.xdg.configHome}/themes/$active_theme"
    '';
  };
}
