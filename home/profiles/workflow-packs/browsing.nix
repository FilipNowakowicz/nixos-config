{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.workflowPacks.browsing;
  inherit (config.fleet) skipHeavyPackages;
in
{
  config = lib.mkIf (cfg.enable && !skipHeavyPackages) {
    home.packages = with pkgs; [ chromium ];
  };
}
