{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.themes;

  # Directory where themes are stored (themes/, mako-config.template, active.nix)
  inherit (cfg) themeDir;
  themesDir = themeDir + /themes;
  makoTemplate = builtins.readFile (themeDir + /mako-config.template);

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
  runtimeActiveThemeFile = cfg.activeFile;

  # The runtime switcher. Lives with the module so the public homeModule ships
  # both halves of the system; the build-time generation above and this script
  # consume the same generated assets. Paths it needs are injected here rather
  # than discovered from the environment.
  themeSwitch = pkgs.writeShellApplication {
    name = "theme-switch";
    runtimeInputs = with pkgs; [
      home-manager
      hyprland
      waybar
      swaybg
      kitty
      procps
      systemd
      util-linux
      libnotify
      fzf
    ];
    text = ''
      ACTIVE_FILE=${lib.escapeShellArg cfg.activeFile}
    ''
    + builtins.readFile ../files/scripts/theme-switch.sh;
  };

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

      # 16 colors — ANSI palette derived per-theme (see theme's ansiColors).
      color0  #${theme.ansiColors.color0}
      color8  #${theme.ansiColors.color8}
      color1  #${theme.ansiColors.color1}
      color9  #${theme.ansiColors.color9}
      color2  #${theme.ansiColors.color2}
      color10 #${theme.ansiColors.color10}
      color3  #${theme.ansiColors.color3}
      color11 #${theme.ansiColors.color11}
      color4  #${theme.ansiColors.color4}
      color12 #${theme.ansiColors.color12}
      color5  #${theme.ansiColors.color5}
      color13 #${theme.ansiColors.color13}
      color6  #${theme.ansiColors.color6}
      color14 #${theme.ansiColors.color14}
      color7  #${theme.ansiColors.color7}
      color15 #${theme.ansiColors.color15}
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
    "themes/${themeName}/mako-config".text =
      lib.replaceStrings
        [
          "@bg@"
          "@text@"
          "@orange@"
        ]
        [
          theme.colors.bg
          theme.colors.text
          theme.colors.orange
        ]
        makoTemplate;

    # Wallpaper symlink
    "themes/${themeName}/wallpaper".source = theme.wallpaper;

    # Shell-sourceable color vars. The runtime switcher sources this for its
    # live-reload values instead of re-parsing the theme .nix files, so Nix
    # stays the single source of truth for every theme's palette.
    "themes/${themeName}/vars".text = ''
      bg=${theme.colors.bg}
      brown=${theme.colors.brown}
      orange=${theme.colors.orange}
      amber=${theme.colors.amber}
      text=${theme.colors.text}
    '';
  };

  # Generate configs for all valid themes
  themeConfigs = lib.foldl (
    acc: themeName: acc // (mkThemeConfig themeName validThemes.${themeName})
  ) { } (builtins.attrNames validThemes);

in
{
  options.themes = {
    themeDir = lib.mkOption {
      type = lib.types.path;
      default = ./.;
      defaultText = lib.literalExpression "./. (home/theme)";
      description = ''
        Directory holding the theme set: a `themes/` subdirectory of `.nix`
        theme definitions, a `mako-config.template`, and an `active.nix`
        pointer. Point this at your own directory to supply a different set of
        themes without forking the module.
      '';
    };
    active = lib.mkOption {
      type = lib.types.str;
      default = (import (themeDir + /active.nix)).name;
      defaultText = lib.literalExpression "(import \"\${themeDir}/active.nix\").name";
      description = ''
        Name of the active theme. Must match a .nix filename under
        `''${themeDir}/themes/` (without the .nix extension). Defaults to the
        theme selected in `active.nix`, which is the single source of truth that
        the runtime `theme-switch` script rewrites. Theme assets are symlinked
        into XDG config paths for Kitty, Hyprland, Waybar, and Mako on every
        rebuild.
      '';
      example = "mono-mesh";
    };
    activeFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/nix/home/theme/active.nix";
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/nix/home/theme/active.nix"'';
      description = ''
        Absolute path to the working-tree `active.nix` that records the active
        theme as `import ./themes/<name>.nix`. `theme-switch` rewrites it and the
        activation hook reads it, so a runtime switch persists across rebuilds
        and feeds build-time consumers (Neovim colorscheme, GTK light/dark).
        Point it at a file your configuration repository tracks.
      '';
    };
    _activeThemeColors = lib.mkOption {
      type = lib.types.attrs;
      internal = true;
      description = "Color palette of the active theme, exposed for other modules to consume (e.g. generated configs).";
    };
    _activeThemeColorscheme = lib.mkOption {
      type = lib.types.attrs;
      internal = true;
      description = ''
        Neovim colorscheme selection of the active theme (attrs with `name` and
        `background`), exposed for the neovim module to consume.
      '';
    };
  };

  config = {
    themes._activeThemeColors = activeTheme.colors;
    themes._activeThemeColorscheme = activeTheme.colorscheme;
    home.packages = [ themeSwitch ];
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
