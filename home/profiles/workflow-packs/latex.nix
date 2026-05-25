{
  lib,
  config,
  pkgs,
  skipHeavyPackages ? false,
  ...
}:
let
  cfg = config.workflowPacks.latex;
in
{
  config = lib.mkIf (cfg.enable && !skipHeavyPackages) {
    home.packages = with pkgs; [
      zathura
      (texlive.withPackages (ps: [
        ps.scheme-medium
        ps.enumitem
      ]))
    ];
  };
}
