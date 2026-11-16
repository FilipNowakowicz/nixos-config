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
    # Colours come from the active theme (home/theme), which links them to
    # ~/.config/zathura/colors; Ctrl+R recolours the page itself to match.
    programs.zathura = {
      enable = true;
      extraConfig = "include ${config.xdg.configHome}/zathura/colors";
    };
    home.packages = with pkgs; [
      (texlive.withPackages (ps: [
        ps.scheme-medium
        ps.enumitem
        ps.titlesec
      ]))
    ];
  };
}
