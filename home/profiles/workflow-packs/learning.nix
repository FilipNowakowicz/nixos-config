{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.workflowPacks.learning;
  inherit (config.fleet) skipHeavyPackages;
in
{
  config = lib.mkIf (cfg.enable && !skipHeavyPackages) {
    home.packages = with pkgs; [ anki ];
  };
}
