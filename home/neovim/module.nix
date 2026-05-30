{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.neovim;

  mergeAttrList =
    attrsList:
    if attrsList == [ ] then
      { }
    else
      builtins.zipAttrsWith (_: values: lib.concatLists values) attrsList;
  mergeAttrSet = attrsList: lib.foldl' lib.recursiveUpdate { } attrsList;

  enabledPacks =
    lib.optional cfg.languages.c.enable (import ./packs/c.nix { inherit pkgs; })
    ++ lib.optional cfg.languages.nix.enable (import ./packs/nix.nix { inherit pkgs; })
    ++ lib.optional cfg.languages.python.enable (import ./packs/python.nix { inherit pkgs cfg; })
    ++ lib.optional cfg.languages.tex.enable (import ./packs/tex.nix { inherit lib pkgs cfg; });

  packPackages = lib.unique (lib.concatMap (pack: pack.packages or [ ]) enabledPacks);

  languageConfig = {
    c = {
      inherit (cfg.languages.c) enable;
    };
    nix = {
      inherit (cfg.languages.nix) enable;
    };
    python = {
      inherit (cfg.languages.python) dap enable;
      test_runner = cfg.languages.python.testRunner;
    };
    tex = {
      inherit (cfg.languages.tex) enable grammar;
    };
  };

  lspEnable = lib.unique (lib.concatMap (pack: pack.lsp.enable or [ ]) enabledPacks);
  lspSettings = mergeAttrSet (map (pack: pack.lsp.settings or { }) enabledPacks);
  formattersByFt = mergeAttrList (
    [ { lua = [ "stylua" ]; } ] ++ map (pack: pack.formatters or { }) enabledPacks
  );
  lintersByFt = mergeAttrList (map (pack: pack.linters or { }) enabledPacks);
  testsAdapters = lib.concatMap (pack: pack.tests.adapters or [ ]) enabledPacks;
  dapConfigurations = mergeAttrList (map (pack: pack.dap or { }) enabledPacks);
  projectMarkers = mergeAttrList (map (pack: pack.projectMarkers or { }) enabledPacks);
  projectDetection = {
    inherit (cfg.projectDetection) enable;
    markers = projectMarkers;
  };

  # Colorscheme selection comes from the active theme (home/theme), so a theme
  # switch repaints Neovim instead of leaving a hardcoded gruvbox value.
  themeColorscheme = config.themes._activeThemeColorscheme or { };

  generatedConfig = {
    languages = languageConfig;

    ui = {
      colorscheme = {
        name = themeColorscheme.name or "gruvbox-material";
        background = themeColorscheme.background or "dark";
        contrast = themeColorscheme.contrast or "medium";
      };
    };

    lsp = {
      enable = lspEnable;
      settings = lspSettings;
    };

    formatters_by_ft = formattersByFt;

    linters_by_ft = lintersByFt;

    tests = {
      adapters = testsAdapters;
    };

    dap = {
      configurations = dapConfigurations;
    };

    project_detection = projectDetection;
  };

  generatedLua = import ./generators/lua-config.nix {
    inherit generatedConfig pkgs;
  };
  generatedCheatsheet = import ./generators/cheatsheet.nix {
    inherit pkgs;
    staticConfig = ../files/nvim;
  };

  staticConfig = ../files/nvim;

  finalConfig = pkgs.runCommandLocal "nvim-config" { } ''
    mkdir -p "$out"
    cp -R ${staticConfig}/. "$out/"
    chmod -R u+w "$out"
    cp ${generatedLua} "$out/lua/config/generated.lua"
    cp ${generatedCheatsheet} "$out/CHEATSHEET.md"
    ${lib.optionalString (!cfg.cheatsheet.enable) ''rm -f "$out/CHEATSHEET.md"''}
  '';
in
{
  options.my.neovim = {
    enable = lib.mkEnableOption "Lua-first Neovim module";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.neovim-unwrapped;
      defaultText = lib.literalExpression "pkgs.neovim-unwrapped";
      description = "Neovim package to install.";
    };

    cheatsheet.enable = lib.mkEnableOption "CHEATSHEET.md generated in the nvim config directory" // {
      default = true;
    };

    projectDetection.enable =
      lib.mkEnableOption "per-project config detection via root markers (configures LSP roots)"
      // {
        default = true;
      };

    languages = {
      c.enable = lib.mkEnableOption "C/C++ editor tooling (clangd LSP)" // {
        default = false;
      };

      nix.enable = lib.mkEnableOption "Nix editor tooling (nixd LSP, nixfmt formatter)" // {
        default = true;
      };

      python = {
        enable =
          lib.mkEnableOption "Python editor tooling (basedpyright LSP, ruff formatter, neotest, DAP)"
          // {
            default = true;
          };

        testRunner = lib.mkOption {
          type = lib.types.enum [ "pytest" ];
          default = "pytest";
          description = "Python test runner adapter for neotest.";
        };

        dap = lib.mkEnableOption "Python DAP debug adapter profiles (debugpy)" // {
          default = true;
        };
      };

      tex = {
        enable = lib.mkEnableOption "LaTeX editor tooling (texlab LSP, latexmk build)";

        grammar = lib.mkEnableOption "LTeX grammar and spell checking (slower; catches prose issues in .tex files)";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      cfg.package
      pkgs.glow
      pkgs.lazygit
      pkgs.stylua
      pkgs.tree-sitter
    ]
    ++ lib.optionals cfg.languages.c.enable [
      pkgs.gcc
      pkgs.gnumake
    ]
    ++ packPackages;

    xdg.configFile."nvim".source = finalConfig;
  };
}
