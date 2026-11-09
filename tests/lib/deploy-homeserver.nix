# Deployment policy tests use stubs and require no deployment credentials.
{ nixpkgs, system, ... }:
let
  pkgs = nixpkgs.legacyPackages.${system};
in
pkgs.runCommand "deploy-homeserver-contract"
  {
    src = ../../.;
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      gnugrep
      jq
      nodejs
    ];
  }
  ''
    bash "$src/scripts/test-deploy-homeserver.sh"
    touch "$out"
  ''
