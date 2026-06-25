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

  failures = lib.runTests {
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
        "brown=${monoTheme.colors.brown}"
        "orange=${monoTheme.colors.orange}"
        "amber=${monoTheme.colors.amber}"
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
      expected = [
        "kitty"
        "waybar"
        "swaybg"
      ];
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
  };
in
if failures == [ ] then
  pkgs.runCommand "theme-module-tests" { } "touch $out"
else
  throw "tests/home/theme-module.nix tests failed:\n${lib.generators.toPretty { } failures}"
