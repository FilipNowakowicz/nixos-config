{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.workflowPacks.latex;
  inherit (config.fleet) skipHeavyPackages;
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
