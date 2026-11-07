# Spotlight's sums, conversions and learning are plain JavaScript, so node checks
# them directly. rates.py runs against the fake curl the acceptance suite uses.
{
  nixpkgs,
  system,
  ...
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
in
pkgs.runCommand "quiet-shell-search-tests"
  {
    nativeBuildInputs = [
      pkgs.nodejs
      pkgs.python3
    ];
  }
  ''
    node ${./quiet-shell-search.js} ${../../packages/quiet-shell/shell/Search.js}
    python3 ${./quiet-shell-rates.py} \
      ${../../packages/quiet-shell/shell/scripts/rates.py} \
      ${../quiet-shell/fakes/fake.py}
    touch $out
  ''
