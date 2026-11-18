{
  nixpkgs,
  system,
  ...
}:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};

  themeModulePath = ../../home/theme/module.nix;
  themeDir = ../../home/theme;

  # The theme module reads `config`, `lib`, and `pkgs`, so we can apply it
  # directly with a minimal stub and inspect the generated outputs without
  # booting a full Home Manager evaluation. The switcher package it puts in
  # home.packages stays a lazy thunk we never force.
  stubConfig = active: {
    themes = {
      inherit active;
      inherit themeDir;
      activeFile = "/home/test/active.nix";
    };
    home.homeDirectory = "/home/test";
    xdg.configHome = "/home/test/.config";
  };

  evalModule =
    active:
    import themeModulePath {
      config = stubConfig active;
      inherit lib pkgs;
    };

  evalThemed = active: (evalModule active).config;
  evalOptions = (evalModule "mono-mesh").options;

  themed = evalThemed "mono-mesh";
  files = themed.xdg.configFile;

  # Mirrors the copyable `homeModules.runtime-theme` usage example in
  # docs/theme.md — a stranger's own `themeDir`/`activeFile` overrides,
  # evaluated against nixpkgs only (no `hosts/`, no real paths or secrets) —
  # proving the documented snippet evaluates standalone.
  docExampleConfig = {
    themes = {
      themeDir = ../../home/theme;
      activeFile = "/home/you/dotfiles/theme/active.nix";
    };
    home.homeDirectory = "/home/you";
    xdg.configHome = "/home/you/.config";
  };

  docExampleThemed =
    (import themeModulePath {
      config = docExampleConfig;
      inherit lib pkgs;
    }).config;

  monoTheme = import ../../home/theme/themes/mono-mesh.nix;
  varsText = files."themes/mono-mesh/vars".text;
  kittyText = files."themes/mono-mesh/kitty-theme.conf".text;
  # Thumbnails are store paths, which fromJSON refuses to see in its input.
  shellColorsText =
    builtins.unsafeDiscardStringContext
      files."themes/mono-mesh/quiet-colors.json".text;

  failures = lib.runTests {
    testQuietShellColors = {
      expr = builtins.fromJSON shellColorsText;
      expected = {
        name = "mono-mesh";
        inherit (monoTheme.colors) bg text;
        accent = monoTheme.colors.accent;
        appearance = "dark";
        themes = builtins.fromJSON (builtins.toJSON (builtins.fromJSON shellColorsText).themes);
      };
    };

    # The picker gets every theme with its title, palette and a thumbnail.
    testPickerEntries =
      let
        entries = (builtins.fromJSON shellColorsText).themes;
        mono = lib.findFirst (e: e.name == "mono-mesh") null entries;
      in
      {
        expr = {
          count = builtins.length entries;
          mono = removeAttrs mono [ "thumbnail" ];
          thumbnailIsStorePath = lib.hasPrefix builtins.storeDir mono.thumbnail;
        };
        expected = {
          count = builtins.length (builtins.attrNames (builtins.readDir ../../home/theme/themes));
          mono = {
            name = "mono-mesh";
            title = monoTheme.displayName;
            inherit (monoTheme.colors)
              bg
              surface
              accent
              text
              ;
          };
          thumbnailIsStorePath = true;
        };
      };

    testHyprlandLuaColors = {
      expr = lib.all (line: lib.hasInfix line files."themes/mono-mesh/hypr-colors.lua".text) [
        "return {"
        "active = \"rgb(${monoTheme.colors.accent})\""
        "inactive = \"rgb(${monoTheme.colors.surface})\""
        "shadow = \"rgba(${monoTheme.colors.bg}cc)\""
      ];
      expected = true;
    };

    # The runtime switcher sources this vars file instead of re-parsing .nix.
    testVarsFileGenerated = {
      expr = files ? "themes/mono-mesh/vars";
      expected = true;
    };

    # vars exposes the full color contract straight from the theme definition,
    # making Nix the single source of truth for the runtime switcher's colors.
    testVarsExposeColorContract = {
      expr = lib.all (line: lib.hasInfix line varsText) [
        "bg=${monoTheme.colors.bg}"
        "surface=${monoTheme.colors.surface}"
        "secondary=${monoTheme.colors.secondary}"
        "accent=${monoTheme.colors.accent}"
        "text=${monoTheme.colors.text}"
      ];
      expected = true;
    };

    # Kitty colors come from the per-theme ANSI palette, not a hardcoded
    # fallback — this is the divergence the old shell generator introduced.
    testKittyUsesAnsiPalette = {
      expr = lib.hasInfix "color9  #${monoTheme.ansiColors.color9}" kittyText;
      expected = true;
    };

    # active.nix is the single source for which theme is active.
    testActiveDefaultsFromActiveNix = {
      expr = evalOptions.themes.active.default;
      expected = (import ../../home/theme/active.nix).name;
    };

    # activeFile defaults to a working-tree path derived from the home dir.
    testActiveFileDefault = {
      expr = evalOptions.themes.activeFile.default;
      expected = "/home/test/nix/home/theme/active.nix";
    };

    # The module ships the runtime switcher itself (the public homeModule must
    # provide both halves of the system).
    testSwitcherShipped = {
      expr = builtins.length themed.home.packages >= 1;
      expected = true;
    };

    # `home/profiles/desktop-runtime.nix` is the single shared list of
    # theme-reloaded Wayland UI packages, consumed by BOTH the desktop install
    # list (home/profiles/desktop.nix) and this module's themeSwitch
    # runtimeInputs (home/theme/module.nix). Pin its exact contents so the
    # documented `runtime-theme` "what to theme" contract cannot silently drift;
    # both consumers import this same file, so the two lists stay identical by
    # construction and this assertion guards the shared source itself.
    testRuntimeThemeContract = {
      expr = map (p: p.pname) (import ../../home/profiles/desktop-runtime.nix { inherit pkgs; });
      expected = [ "kitty" ];
    };

    # The docs/theme.md `homeModules.runtime-theme` example — overriding
    # `themeDir`/`activeFile` for a stranger's own dotfiles repo, evaluated
    # against nixpkgs only with no `hosts/` import — must evaluate and
    # activate the switcher, proving the copyable snippet works standalone.
    testDocExampleActivatesSwitcher = {
      expr = builtins.length docExampleThemed.home.packages >= 1;
      expected = true;
    };

    # The example also generates the per-theme assets the switcher relinks,
    # so the documented override is more than a no-op import.
    testDocExampleGeneratesThemeAssets = {
      expr = docExampleThemed.xdg.configFile ? "themes/mono-mesh/vars";
      expected = true;
    };

    # Neovim's base16 palette is built from the theme: background from bg,
    # functions in the accent, and the theme's appearance.
    testNvimPalette = {
      expr =
        let
          text = files."themes/mono-mesh/nvim-palette.lua".text;
        in
        lib.all (s: lib.hasInfix s text) [
          ''["background"] = "dark"''
          ''["base00"] = "#${monoTheme.colors.bg}"''
          ''["base05"] = "#${monoTheme.colors.text}"''
          ''["base0D"] = "#${monoTheme.colors.accent}"''
        ];
      expected = true;
    };

    # The palette is relinked with the other assets on every switch.
    testNvimPaletteLinked = {
      expr = lib.hasInfix "nvim-palette.lua" files."themes/links.sh".text;
      expected = true;
    };

    # The light theme carries its appearance to the switcher (GTK, portal) and
    # to Neovim, whose strongest foreground is then dark ink, not white.
    testLightThemeAppearance =
      let
        paper = import ../../home/theme/themes/paper-contours.nix;
        palette = files."themes/paper-contours/nvim-palette.lua".text;
      in
      {
        expr = {
          vars = lib.hasInfix "appearance=light" files."themes/paper-contours/vars".text;
          background = lib.hasInfix ''["background"] = "light"'' palette;
          ink = lib.hasInfix ''["base07"] = "#${paper.ansiColors.color0}"'' palette;
        };
        expected = {
          vars = true;
          background = true;
          ink = true;
        };
      };

    # A theme on the old brown/orange/amber keys is rejected at evaluation.
    testStaleColorKeysRejected = {
      expr =
        (builtins.tryEval (
          builtins.attrNames
            (import themeModulePath {
              config = lib.recursiveUpdate (stubConfig "stale") {
                themes.themeDir = ./fixtures/stale-theme;
              };
              inherit lib pkgs;
            }).config.xdg.configFile
        )).success;
      expected = false;
    };

    # Every shipped theme passes the same contract.
    testAllThemesValid = {
      expr = lib.all (name: files ? "themes/${name}/vars") (
        map (lib.removeSuffix ".nix") (builtins.attrNames (builtins.readDir ../../home/theme/themes))
      );
      expected = true;
    };
  };
in
if failures == [ ] then
  pkgs.runCommand "theme-module-tests" { } "touch $out"
else
  throw "tests/home/theme-module.nix tests failed:\n${lib.generators.toPretty { } failures}"
