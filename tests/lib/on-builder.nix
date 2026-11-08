# Stub cloud/SSH endpoints while retaining real Git and rsync transfer policy.
{ nixpkgs, system, ... }:
let
  pkgs = nixpkgs.legacyPackages.${system};
in
pkgs.runCommand "on-builder-contract"
  {
    src = ../../.;
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      findutils
      git
      gnugrep
      gnused
      gawk
      rsync
      jq
    ];
  }
  ''
    bash "$src/scripts/test-ci-builder.sh"
    touch "$out"
  ''
