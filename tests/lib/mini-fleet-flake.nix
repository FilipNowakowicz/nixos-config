# Static guard for `examples/mini-fleet/flake.nix`: asserts that the copyable
# example references the correct repo URL and only imports public output names
# that actually exist in the root flake.nix.  Mirrors the `lib-doctor` pattern
# (pkgs.runCommand + grep assertions) so it runs in the build phase and is
# caught by `scripts/validate.sh light` and `merge-gate`.
{
  nixpkgs,
  system,
  ...
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
in
pkgs.runCommand "mini-fleet-flake-static"
  {
    src = ../../.;
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      gnugrep
    ];
  }
  ''
    example="$src/examples/mini-fleet/flake.nix"
    root_flake="$src/flake.nix"

    # 1. The example must reference the correct upstream repo URL.
    grep -qF 'github:FilipNowakowicz/nixos-config' "$example" \
      || { echo "mini-fleet/flake.nix: wrong or missing upstream URL (expected github:FilipNowakowicz/nixos-config)" >&2; exit 1; }

    # 2. The example must not reference the old wrong URL.
    if grep -qF 'github:FilipNowakowicz/NixOS' "$example"; then
      echo "mini-fleet/flake.nix: still references old wrong URL github:FilipNowakowicz/NixOS" >&2
      exit 1
    fi

    # 3. Each public output the example imports must (a) appear in the example
    #    file under its full dotted name, and (b) exist as a bare attr in the
    #    root flake.nix so a rename in the root immediately breaks this check.
    #    Both facts derive from this single list — no parallel copy to drift.
    for name in \
      nixosModules.profiles-desktop \
      nixosModules.profiles-security \
      nixosModules.services-hardened \
      nixosModules.observability-stack \
      nixosModules.observability-client \
      homeModules.profiles-base
    do
      grep -qF "$name" "$example" \
        || { echo "mini-fleet/flake.nix: missing expected public output reference: $name" >&2; exit 1; }
      attr="''${name##*.}"
      kind="''${name%%.*}"
      grep -qF "$attr" "$root_flake" \
        || { echo "flake.nix: public $kind output '$attr' used by mini-fleet example is missing from root flake" >&2; exit 1; }
    done

    touch "$out"
  ''
