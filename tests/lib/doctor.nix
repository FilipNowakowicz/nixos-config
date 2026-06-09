# Golden check for `nix run .#doctor`'s public contract: a stranger running it
# from a clean clone must see a stable set of named sections, each explained in
# plain terms. This guards against the banner names or their explanations
# silently drifting away from the failure modes the public README/issue promise
# (missing Nix, unsupported platform, dirty formatting, broken docs, evaluation
# error) — without having to build the heavy checks doctor itself runs.
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

  # Ordered list of `section "<name>"` banners doctor.sh must print, paired
  # with a keyword that must appear in that section's explanation. Keep this
  # in sync with scripts/doctor.sh — both are read by mkSectionAssertions
  # and exercised by the runCommand below.
  expectedSections = [
    {
      name = "Nix availability";
      keyword = "nix";
    }
    {
      name = "Supported platform";
      keyword = "system";
    }
    {
      name = "Repository documentation";
      keyword = "Markdown link";
    }
    {
      name = "CI plan generator";
      keyword = "CI plan generator";
    }
    {
      name = "Cache configuration consistency";
      keyword = "cache";
    }
    {
      name = "Secrets directory hygiene";
      keyword = "plaintext";
    }
    {
      name = "Flake evaluation";
      keyword = "evaluat";
    }
    {
      name = "Formatting";
      keyword = "nix fmt";
    }
    {
      name = "Light build/invariant suite";
      keyword = "invariants";
    }
    {
      name = "Sample inventory data build";
      keyword = "inventory";
    }
  ];

  mkSectionAssertions = lib.concatMapStringsSep "\n" (
    { name, keyword }:
    ''
      grep -qF 'section "${name}"' "$doctor" \
        || { echo "doctor.sh: missing public-contract section: ${name}" >&2; exit 1; }
      grep -A6 'section "${name}"' "$doctor" | grep -qF '${keyword}' \
        || { echo "doctor.sh: section '${name}' explanation lost its '${keyword}' anchor" >&2; exit 1; }
    ''
  ) expectedSections;
in
pkgs.runCommand "doctor-sections-golden"
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

    ${mkSectionAssertions}

    # The sections must appear in this exact order in the script source, so
    # the printed banner order (and therefore the public narrative) is stable.
    actual_order="$(grep -oP '(?<=section ")[^"]+' "$doctor" | tr '\n' '|')"
    expected_order="${lib.concatMapStringsSep "|" ({ name, ... }: name) expectedSections}|"
    if [[ "$actual_order" != "$expected_order" ]]; then
      echo "doctor.sh: section order/contents drifted from the golden list" >&2
      echo "  expected: $expected_order" >&2
      echo "  actual:   $actual_order" >&2
      exit 1
    fi

    # The doctor entrypoint must stay framed for a stranger, not the fleet
    # operator: it must not name hosts, secrets paths, or "fleet" jargon in
    # its narration (the sections may still *check* secrets hygiene, but must
    # explain it in public-reader terms, which the keyword assertions above
    # already cover).
    if grep -qiE 'hosts/(${privateHostAlternation})\b' "$doctor"; then
      echo "doctor.sh: must not name specific private hosts in its narration" >&2
      exit 1
    fi

    touch "$out"
  ''
