{
  lib,
  pkgs,
  cfg,
}:
{
  packages = [ pkgs.texlab ] ++ lib.optional cfg.languages.tex.grammar pkgs.ltex-ls-plus;

  lsp = {
    enable = [ "texlab" ];
    settings = {
      texlab = {
        texlab = {
          build = {
            onSave = false;
          };
          chktex = {
            onOpenAndSave = true;
          };
        };
      };
    };
  };

  formatters = { };

  linters = { };

  tests.adapters = [ ];

  dap = { };

  projectMarkers = {
    tex = [
      ".latexmkrc"
      "latexmkrc"
    ];
  };
}
