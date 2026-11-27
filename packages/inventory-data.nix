{
  lib,
  pkgs,
  hostRegistry,
  allNixosConfigs,
  hostAssertions ? { },
}:
let
  inventoryData = import ../lib/inventory-data.nix {
    inherit
      lib
      pkgs
      hostRegistry
      allNixosConfigs
      hostAssertions
      ;
  };
in
pkgs.runCommand "inventory-data"
  {
    dataJson = builtins.toJSON inventoryData.data;
    passAsFile = [ "dataJson" ];
  }
  ''
    mkdir -p "$out"
    cp "$dataJsonPath" "$out/inventory.json"
  ''
