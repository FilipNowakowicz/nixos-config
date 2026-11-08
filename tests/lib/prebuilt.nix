{ nixpkgs, system, ... }:
let
  pkgs = nixpkgs.legacyPackages.${system};
  fixture = pkgs.runCommand "nixos-system-main-fixture" { } ''
    mkdir -p "$out/bin"
    printf '#!/bin/sh\nexit 99\n' > "$out/bin/switch-to-configuration"
    chmod +x "$out/bin/switch-to-configuration"
  '';
in
pkgs.runCommand "prebuilt-contract"
  {
    src = ../../.;
    TEST_SYSTEM_PATH = fixture;
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      jq
      gnused
      gnugrep
      diffutils
    ];
  }
  ''
    bash "$src/scripts/test-builder-prebuild.sh"
    bash "$src/scripts/test-rebuild-prebuilt.sh"
    touch "$out"
  ''
