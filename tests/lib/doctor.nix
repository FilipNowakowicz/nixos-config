# Contract check for `nix run .#doctor`. The README promises that doctor
# explains five failure modes in plain terms: missing Nix, an unsupported
# platform, a broken doc link, an evaluation error and dirty formatting. Each
# must keep a section whose banner or explanation names it, and the narration
# must stay framed for a stranger rather than this fleet's operator.
#
# Section names, their order and doctor's contributor-facing sections (CI
# planning, cache settings, secrets hygiene) are deliberately not pinned:
# rewording or reordering the narration is not a contract change.
{
  nixpkgs,
  system,
  ...
}:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};

  # Private host names come from the registry (single source of truth), so a
  # host added to lib/hosts.nix is automatically forbidden in doctor narration
  # without editing this denylist by hand.
  privateHostAlternation = lib.concatStringsSep "|" (builtins.attrNames (import ../../lib/hosts.nix));

  # Promised failure mode -> an extended regex one section must match in its
  # banner or the explanation that follows it.
  promisedFailureModes = {
    "missing Nix" = "'nix' command is missing";
    "unsupported platform" = "unsupported system";
    "broken doc link" = "Markdown link";
    "evaluation error" = "cannot be evaluated";
    "dirty formatting" = "formatted the way 'nix fmt'";
  };

  mkFailureModeAssertions = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (mode: pattern: ''
      grep -A6 '^ *section "' "$doctor" | grep -qiE ${lib.escapeShellArg pattern} \
        || { echo "doctor.sh: no section explains the promised failure mode: ${mode}" >&2; exit 1; }
    '') promisedFailureModes
  );
in
pkgs.runCommand "doctor-contract"
  {
    src = ../../.;
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      gnugrep
    ];
  }
  ''
    doctor="$src/scripts/doctor.sh"

    ${mkFailureModeAssertions}

    # Doctor must still end by telling the reader the tree is healthy.
    grep -qF 'all checks passed' "$doctor" \
      || { echo "doctor.sh: lost its final success message" >&2; exit 1; }

    if grep -qiE 'hosts/(${privateHostAlternation})\b' "$doctor"; then
      echo "doctor.sh: must not name specific private hosts in its narration" >&2
      exit 1
    fi

    touch "$out"
  ''
