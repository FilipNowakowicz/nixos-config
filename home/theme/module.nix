{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.themes;

  # Directory where themes are stored (themes/, active.nix)
  inherit (cfg) themeDir;
  themesDir = themeDir + /themes;

  # Auto-discover all theme files
  themeFiles = builtins.readDir themesDir;

  # The color contract. Every template below reads these slots by name, so a
  # theme with a missing or misspelt slot fails here, naming the theme, rather
  # than as an attribute error deep inside one template.
  colorSlots = [
    "accent"
    "bg"
    "secondary"
    "surface"
    "text"
  ];
  ansiSlots = map (i: "color${toString i}") (lib.range 0 15);
  isHex = v: builtins.isString v && builtins.match "[0-9a-fA-F]{6}" v != null;

  checkSlots =
    themeName: what: slots: attrs:
    let
      names = builtins.attrNames attrs;
      missing = lib.subtractLists names slots;
      extra = lib.subtractLists slots names;
      badHex = lib.filter (n: !isHex attrs.${n}) (lib.intersectLists names slots);
      problems =
        lib.optional (missing != [ ]) "is missing ${lib.concatStringsSep ", " missing}"
        ++ lib.optional (extra != [ ]) "has unknown ${lib.concatStringsSep ", " extra}"
        ++ lib.optional (badHex != [ ]) "needs rrggbb hex in ${lib.concatStringsSep ", " badHex}";
    in
    lib.throwIf (problems != [ ]) "theme ${themeName}: ${what} ${lib.concatStringsSep "; " problems}";

  appearances = [
    "dark"
    "light"
  ];

  validate =
    themeName: theme:
    lib.throwIfNot (lib.elem (theme.appearance or "dark") appearances)
      "theme ${themeName}: appearance must be one of ${lib.concatStringsSep ", " appearances}"
      (
        checkSlots themeName "colors" colorSlots (theme.colors or { }) (
          checkSlots themeName "ansiColors" ansiSlots (theme.ansiColors or { }) theme
        )
      );

  # Load and validate each theme
  allThemes = lib.mapAttrs' (
    name: _:
    let
      themePath = themesDir + "/${name}";
      themeName = lib.removeSuffix ".nix" name;
      theme = validate themeName (import themePath);
    in
    lib.nameValuePair themeName (
      {
        appearance = "dark";
      }
      // theme
      // {
        name = themeName;
      }
    )
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
  runtimeStateFile = "${config.xdg.stateHome}/theme/active";

  # Shows the linked wallpaper through the running awww daemon, waiting up to
  # five seconds for it to answer. $1 is the transition: "fade" for a theme
  # switch, "none" when the unit starts.
  wallpaperFile = "${config.home.homeDirectory}/.local/share/wallpapers/current.png";
  wallpaperShow = pkgs.writeShellScript "wallpaper-show" ''
    for ((i = 0; i < 50; i++)); do
      ${pkgs.awww}/bin/awww query >/dev/null 2>&1 && break
      ${pkgs.coreutils}/bin/sleep 0.1
    done
    exec ${pkgs.awww}/bin/awww img --transition-type "''${1:-fade}" \
      --transition-duration 0.8 --transition-fps 60 ${lib.escapeShellArg wallpaperFile}
  '';

  # The runtime switcher. Lives with the module so the public homeModule ships
  # both halves of the system; the build-time generation above and this script
  # consume the same generated assets. Paths it needs are injected here rather
  # than discovered from the environment.
  themeSwitch = pkgs.writeShellApplication {
    name = "theme-switch";
    # The themed UI tools (kitty) come from the single shared
    # list so they cannot drift from the desktop install list; hyprland is
    # added here for `hyprctl` reloads (the compositor itself is system-level).
    runtimeInputs =
      (import ../profiles/desktop-runtime.nix { inherit pkgs; })
      ++ (with pkgs; [
        home-manager
        hyprland
        procps
        systemd
        util-linux
        libnotify
        fzf
      ]);
    text = ''
      ACTIVE_FILE=${lib.escapeShellArg cfg.activeFile}
      STATE_FILE=${lib.escapeShellArg runtimeStateFile}
      WALLPAPER_SHOW=${wallpaperShow}
    ''
    + builtins.readFile ../files/scripts/theme-switch.sh;
  };

  themeLinkTargets = [
    {
      source = "kitty-theme.conf";
      target = "${config.xdg.configHome}/kitty/current-theme.conf";
    }
    {
      source = "hypr-colors.lua";
      target = "${config.xdg.configHome}/hypr/colors.lua";
    }
    {
      source = "hyprlock-colors.conf";
      target = "${config.xdg.configHome}/hypr/hyprlock-colors.conf";
    }
    {
      source = "zathura-colors";
      target = "${config.xdg.configHome}/zathura/colors";
    }
    {
      source = "quiet-colors.json";
      target = "${config.xdg.configHome}/quiet-shell/colors.json";
    }
    {
      source = "wallpaper";
      target = wallpaperFile;
    }
    {
      source = "nvim-palette.lua";
      target = nvimPaletteFile;
    }
    {
      source = "btop.theme";
      target = "${config.xdg.configHome}/btop/themes/desktop.theme";
    }
    {
      source = "yazi-theme.toml";
      target = "${config.xdg.configHome}/yazi/theme.toml";
    }
  ];

  # Neovim's own config directory is a store path, so its palette link lives
  # beside the theme assets instead; the neovim module reads it from here.
  nvimPaletteFile = "${config.xdg.configHome}/themes/nvim-palette.lua";

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
        }

        # GTK 3 reads its theme name, and GTK 4, libadwaita and the settings
        # portal (so Firefox) read color-scheme, live from these dconf keys. The
        # module owns both, so nothing at build time pins dark or light.
        apply_theme_appearance() {
          local scheme=prefer-dark gtk_theme=Adwaita-dark
          if [[ "$1" == light ]]; then
            scheme=prefer-light gtk_theme=Adwaita
          fi
          local session=()
          if [[ ! -v DBUS_SESSION_BUS_ADDRESS ]]; then
            session=(${pkgs.dbus}/bin/dbus-run-session --dbus-daemon=${pkgs.dbus}/bin/dbus-daemon)
          fi
          printf "[org/gnome/desktop/interface]\ncolor-scheme='%s'\ngtk-theme='%s'\n" "$scheme" "$gtk_theme" |
            "''${session[@]}" ${pkgs.dconf}/bin/dconf load /
        }
  '';

  # A small crop of each wallpaper for the shell's theme picker, at twice the
  # size the picker draws it. Built once per wallpaper, not at switch time.
  mkThumbnail =
    themeName: theme:
    pkgs.runCommandLocal "theme-thumbnail-${themeName}.jpg"
      { nativeBuildInputs = [ pkgs.imagemagick ]; }
      ''
        magick ${theme.wallpaper} -strip -alpha off -resize '208x117^' \
          -gravity center -extent 208x117 -quality 88 "$out"
      '';

  # What the picker shows for every theme: its name, a wallpaper thumbnail and
  # the colours it paints the shell with. Identical in every theme's JSON.
  pickerEntries = lib.mapAttrsToList (themeName: theme: {
    name = themeName;
    title = theme.displayName or themeName;
    inherit (theme.colors)
      bg
      surface
      accent
      text
      ;
    thumbnail = "${mkThumbnail themeName theme}";
  }) validThemes;

  # "rrggbb" -> "rgba(r,g,b,alpha)", for options that take no hex alpha.
  rgba =
    hex: alpha:
    let
      channel = i: toString (lib.fromHexString (builtins.substring i 2 hex));
    in
    "rgba(${channel 0},${channel 2},${channel 4},${alpha})";

  # Blend two "rrggbb" colours: 0 gives `from`, 1 gives `to`.
  mix =
    from: to: t:
    let
      channels =
        hex:
        map (i: lib.fromHexString (builtins.substring i 2 hex)) [
          0
          2
          4
        ];
      byte =
        n:
        let
          s = lib.toLower (lib.toHexString n);
        in
        if builtins.stringLength s < 2 then "0${s}" else s;
    in
    lib.concatStrings (
      lib.zipListsWith (a: b: byte (builtins.floor (a + (b - a) * t + 0.5))) (channels from) (channels to)
    );

  # A base16 scheme from the theme's palette, for Neovim (mini.base16). The
  # greys run from bg toward text, so the same rule serves dark and light
  # themes; the hues come from the bright ANSI slots, which read better as
  # text than the normal ones. Functions take the theme's accent, so each
  # theme's signature colour is the most frequent one in code.
  base16 =
    theme:
    let
      c = theme.colors;
      a = theme.ansiColors;
      # The strongest foreground: bright white on a dark theme, black on a light one.
      ink = if theme.appearance == "light" then a.color0 else a.color15;
    in
    {
      base00 = c.bg; # editor background
      base01 = mix c.bg c.surface 0.6; # status line, cursor line, float bg
      base02 = mix c.bg c.text 0.18; # selection
      base03 = mix c.bg c.text 0.42; # comments, line numbers
      base04 = mix c.bg c.text 0.62; # dark foreground: status text
      base05 = c.text; # foreground
      base06 = mix c.text ink 0.5;
      base07 = ink;
      base08 = a.color9; # variables, tags, deleted diff
      base09 = mix a.color9 a.color11 0.5; # constants, numbers
      base0A = a.color11; # types, search
      base0B = a.color10; # strings, added diff
      base0C = a.color14; # escapes, regex
      base0D = c.accent; # functions
      base0E = a.color13; # keywords
      base0F = mix a.color1 a.color3 0.5; # deprecated, embedded
    };

  # Helper to generate theme config text
  mkThemeConfig = themeName: theme: {
    # Kitty theme
    "themes/${themeName}/kitty-theme.conf".text = ''
      # vim:ft=kitty
      ## name: ${themeName}

      foreground           #${theme.colors.text}
      background           #${theme.colors.bg}
      selection_foreground #${theme.colors.text}
      selection_background #${theme.colors.surface}

      cursor            #${theme.colors.accent}
      cursor_text_color #${theme.colors.bg}

      url_color #${theme.colors.accent}

      active_border_color   #${theme.colors.accent}
      inactive_border_color #${theme.colors.surface}
      bell_border_color     #${theme.colors.secondary}

      wayland_titlebar_color #${theme.colors.bg}

      active_tab_foreground   #${theme.colors.text}
      active_tab_background   #${theme.colors.bg}
      inactive_tab_foreground #${mix theme.colors.bg theme.colors.text 0.45}
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
    "themes/${themeName}/hypr-colors.lua".text = ''
      return {
        active = "rgb(${theme.colors.accent})",
        inactive = "rgb(${theme.colors.surface})",
        shadow = "rgba(${theme.colors.bg}cc)",
        background = "rgb(${theme.colors.bg})",
      }
    '';

    # Hyprlock colors
    "themes/${themeName}/hyprlock-colors.conf".text = ''
      $text      = rgb(${theme.colors.text})
      $bg        = rgb(${theme.colors.bg})
      $accent    = rgb(${theme.colors.accent})
      $secondary = rgb(${theme.colors.secondary})
      $muted     = rgba(${theme.colors.text}b3)
      $glass     = rgba(${theme.colors.text}d9)
      $field     = rgba(${theme.colors.bg}80)
      $edge      = rgba(${theme.colors.text}2e)
      # No theme defines a red, and a failed unlock should read as an error
      # in every theme, so this one stays fixed.
      $fail      = rgb(cc241d)
    '';

    # Zathura reads this at start and on :source. Its D-Bus interface has no
    # way to run a command, so open windows keep their colours until then.
    "themes/${themeName}/zathura-colors".text = ''
      set default-bg "#${theme.colors.bg}"
      set default-fg "#${theme.colors.text}"
      set statusbar-bg "#${theme.colors.surface}"
      set statusbar-fg "#${theme.colors.text}"
      set inputbar-bg "#${theme.colors.bg}"
      set inputbar-fg "#${theme.colors.text}"
      set notification-bg "#${theme.colors.surface}"
      set notification-fg "#${theme.colors.text}"
      set notification-warning-bg "#${theme.colors.surface}"
      set notification-warning-fg "#${theme.colors.accent}"
      set notification-error-bg "#${theme.colors.surface}"
      set notification-error-fg "#${theme.colors.secondary}"
      set completion-bg "#${theme.colors.surface}"
      set completion-fg "#${theme.colors.text}"
      set completion-group-bg "#${theme.colors.bg}"
      set completion-group-fg "#${theme.colors.accent}"
      set completion-highlight-bg "#${theme.colors.accent}"
      set completion-highlight-fg "#${theme.colors.bg}"
      set index-bg "#${theme.colors.bg}"
      set index-fg "#${theme.colors.text}"
      set index-active-bg "#${theme.colors.accent}"
      set index-active-fg "#${theme.colors.bg}"
      set highlight-color "${rgba theme.colors.accent "0.4"}"
      set highlight-active-color "${rgba theme.colors.secondary "0.6"}"
      set recolor-lightcolor "#${theme.colors.bg}"
      set recolor-darkcolor "#${theme.colors.text}"
      set recolor-keephue true
    '';

    # yazi's own theme already uses the 16 terminal colours, which kitty
    # repaints live; this puts the theme's accent where it uses blue: the mode
    # badge, the active tab, the working directory and popup borders. yazi
    # reads it when it starts.
    "themes/${themeName}/yazi-theme.toml".source =
      let
        c = theme.colors;
        accent = "#${c.accent}";
        border.border.fg = accent;
      in
      (pkgs.formats.toml { }).generate "yazi-theme-${themeName}.toml" {
        mgr.cwd.fg = accent;
        tabs = {
          active = {
            fg = "#${c.bg}";
            bg = accent;
            bold = true;
          };
          inactive = {
            fg = accent;
            bg = "#${c.surface}";
          };
        };
        mode = {
          normal_main = {
            fg = "#${c.bg}";
            bg = accent;
            bold = true;
          };
          normal_alt = {
            fg = accent;
            bg = "#${c.surface}";
          };
        };
        which = border;
        confirm = border // {
          title.fg = accent;
        };
        spot = border // {
          title.fg = accent;
        };
        pick = border;
        input = border;
        cmp = border;
        tasks = border;
        help = border;
      };

    # btop reads this through color_theme = "desktop" and again on SIGUSR2 from
    # theme-switch. Quiet boxes and meters in the theme's own greys, with every
    # gradient climbing through the accent; temperatures end in the ANSI red.
    "themes/${themeName}/btop.theme".text =
      let
        c = theme.colors;
        faint = mix c.bg c.text 0.22;
        dim = mix c.bg c.text 0.4;
        soft = mix c.bg c.text 0.65;
        low = mix c.bg c.accent 0.45;
        entries = {
          main_bg = c.bg;
          main_fg = c.text;
          title = c.text;
          hi_fg = c.accent;
          selected_bg = c.surface;
          selected_fg = c.text;
          inactive_fg = dim;
          graph_text = soft;
          meter_bg = c.surface;
          proc_misc = c.accent;
          cpu_box = faint;
          mem_box = faint;
          net_box = faint;
          proc_box = faint;
          div_line = c.surface;
          temp_start = low;
          temp_mid = c.accent;
          temp_end = theme.ansiColors.color9;
          cpu_start = low;
          cpu_mid = c.accent;
          cpu_end = c.text;
          free_start = c.surface;
          free_mid = low;
          free_end = c.accent;
          cached_start = c.surface;
          cached_mid = dim;
          cached_end = soft;
          available_start = c.surface;
          available_mid = low;
          available_end = c.accent;
          used_start = low;
          used_mid = c.accent;
          used_end = c.text;
          download_start = c.surface;
          download_mid = low;
          download_end = c.accent;
          upload_start = c.surface;
          upload_mid = dim;
          upload_end = c.text;
          process_start = low;
          process_mid = c.accent;
          process_end = c.text;
        };
      in
      lib.concatLines (lib.mapAttrsToList (key: hex: ''theme[${key}]="#${hex}"'') entries);

    # Neovim loads this at start and again on SIGUSR1 from theme-switch.
    "themes/${themeName}/nvim-palette.lua".text = ''
      return ${
        lib.generators.toLua { } {
          name = themeName;
          background = theme.appearance;
          palette = lib.mapAttrs (_: hex: "#${hex}") (base16 theme);
        }
      }
    '';

    # Quiet shell colors, plus the theme list for its picker
    "themes/${themeName}/quiet-colors.json".text = builtins.toJSON {
      name = themeName;
      inherit (theme.colors) bg text accent;
      inherit (theme) appearance;
      themes = pickerEntries;
    };

    # Wallpaper symlink
    "themes/${themeName}/wallpaper".source = theme.wallpaper;

    # Shell-sourceable color vars. The runtime switcher sources this for its
    # live-reload values instead of re-parsing the theme .nix files, so Nix
    # stays the single source of truth for every theme's palette.
    "themes/${themeName}/vars".text = ''
      bg=${theme.colors.bg}
      surface=${theme.colors.surface}
      secondary=${theme.colors.secondary}
      accent=${theme.colors.accent}
      text=${theme.colors.text}
      appearance=${theme.appearance}
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
        theme definitions and an `active.nix`
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
        into XDG config paths for Kitty, Hyprland, Zathura and Quiet Shell on every
        rebuild.
      '';
      example = "mono-mesh";
    };
    activeFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/nix/home/theme/active.nix";
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/nix/home/theme/active.nix"'';
      description = ''
        Absolute path to the working-tree `active.nix` that declares the default
        theme as `import ./themes/<name>.nix`. `theme-switch --save` rewrites it,
        so the next rebuild starts from that theme on a machine with no runtime
        choice yet. A plain `theme-switch` leaves it alone and records its
        choice in XDG state. Point it at a file your configuration repository
        tracks.
      '';
    };
    _nvimPaletteFile = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
      description = ''
        Live link to the running theme's Neovim palette, a Lua file returning
        `{ name, background, palette = { base00 … base0F } }`. The neovim
        module reads it at start and on SIGUSR1.
      '';
    };
  };

  config = {
    themes._nvimPaletteFile = nvimPaletteFile;
    home.packages = [ themeSwitch ];

    # btop takes its colours from the running theme (linked above) over the
    # terminal's own, translucent background. Home Manager owns btop.conf, so
    # settings changed from btop's menu are not kept.
    programs.btop = {
      enable = true;
      settings = {
        color_theme = "desktop";
        theme_background = false;
      };
    };
    xdg.configFile = themeConfigs // {
      "themes/links.sh".text = themeLinksSnippet;
    };

    # The wallpaper is a unit of its own so it outlives whatever started it: a
    # theme switch from the shell used to leave the wallpaper process inside the
    # shell's unit, and a shell restart took the wallpaper with it. awww's daemon
    # stays up across switches; theme-switch asks it to fade to the new image
    # (wallpaperFade), and restarts the unit only if the daemon is gone.
    systemd.user.services.wallpaper = {
      Unit = {
        Description = "Desktop wallpaper";
        PartOf = [ "graphical-session.target" ];
        # A fallback restart per switch can outpace the default limit of five
        # starts in ten seconds, which left no wallpaper until the next switch.
        StartLimitIntervalSec = 0;
        After = [ "graphical-session.target" ];
      };
      Service = {
        # No cache: the image always comes from the theme's link, not from
        # whatever the daemon showed last time.
        ExecStart = "${pkgs.awww}/bin/awww-daemon --no-cache";
        ExecStartPost = "${wallpaperShow} none";
        # A severed Wayland connection can end the daemon cleanly; come back anyway.
        Restart = "always";
        RestartSec = 2;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    # Symlink active theme configs into live app paths on every activation.
    # Read the runtime choice at activation time so a theme-switch survives a
    # rebuild even when the generation was built with another theme.
    home.activation.linkActiveTheme = lib.hm.dag.entryAfter [ "linkGeneration" "dconfSettings" ] ''
      . "${config.xdg.configHome}/themes/links.sh"

      active_theme="${activeTheme.name}"
      state_file=${lib.escapeShellArg runtimeStateFile}
      if [[ -s "$state_file" ]]; then
        runtime_theme=$(<"$state_file")
        if [[ -n "$runtime_theme" && -d "${config.xdg.configHome}/themes/$runtime_theme" ]]; then
          active_theme="$runtime_theme"
        fi
      fi

      link_theme_assets "${config.xdg.configHome}/themes/$active_theme"

      # After dconfSettings, which resets the keys this module owns.
      appearance=$(. "${config.xdg.configHome}/themes/$active_theme/vars" && echo "$appearance")
      if [[ ! -v DRY_RUN ]]; then
        apply_theme_appearance "''${appearance:-dark}" ||
          warnEcho "theme: could not set the GTK colour scheme"
      fi
    '';
  };
}
