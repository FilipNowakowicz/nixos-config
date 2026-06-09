#!/usr/bin/env bash
set -euo pipefail

# `nix run .#doctor` is the recommended first command for a stranger cloning
# this repo. It runs the same clean-clone checks `merge-gate` relies on, but
# explains each section in plain terms so a public reader can tell a real
# problem from noise — without needing private fleet context, secrets, or
# hardware. Keep section names and their explanations stable: a golden check
# (`tests/lib/doctor.nix`) asserts this banner contract so it can't drift
# silently. If you rename or add a section here, update that fixture too.

repo_root="$(
  git rev-parse --show-toplevel 2>/dev/null || pwd
)"
cd "$repo_root"

section() {
  printf '\n=== %s ===\n%s\n\n' "$1" "$2"
}

run() {
  printf -- '--> %s\n' "$*"
  "$@"
}

echo "Doctor: clean-clone health check for this NixOS flake."
echo "Each section below explains what a failure means for a public reader."

section "Nix availability" \
  "Fails if the 'nix' command is missing or too old to run flakes. Install
Nix (https://nixos.org/download) with flakes enabled, then re-run this
command."
run nix --version

section "Supported platform" \
  "Fails if this machine's CPU/OS combination ('system') is not one this
flake evaluates for. The flake targets common Linux and macOS systems; an
unsupported system means flake outputs may not build here even though Nix
itself works."
current_system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
run nix eval ".#devShells.${current_system}.default" --apply builtins.typeOf
echo

section "Repository documentation" \
  "Fails if a Markdown link points at a file or anchor that does not exist,
or if generated docs (the repo map, learning-candidate ledger) are stale.
This usually means a doc was moved/renamed without updating its references —
fix the link or regenerate the doc the error names."
run bash scripts/validate.sh docs

section "CI plan generator" \
  "Fails if the script that decides which CI jobs to run for a given set of
changed files no longer matches its expectations. This is internal plumbing;
a failure here means a recent change to the planner needs a matching update
to its test."
run bash scripts/test-ci-plan.sh

section "Cache configuration consistency" \
  "Fails if the binary cache URL/key advertised in CI setup and the one
hosts trust to fetch pre-built closures from have drifted apart. A mismatch
would make CI or a host fall back to building everything from source."
run bash scripts/check-cache-config.sh

section "Secrets directory hygiene" \
  "Fails if anything under a host's secrets/ directory looks like plaintext
rather than a sops-encrypted blob. This repo never expects to ship secrets in
a clean clone — see this if you're verifying you haven't accidentally staged
something unencrypted."
run bash scripts/check-secrets-directory.sh --working-tree

section "Flake evaluation" \
  "Fails if any flake output (a host system, a package, a check, an app)
cannot be evaluated — for example a Nix syntax error, a missing input, or a
broken reference between modules. The error names the attribute path and file;
that is where to look first."
run bash scripts/validate.sh flake-eval

section "Formatting" \
  "Fails if any tracked file is not formatted the way 'nix fmt' would format
it (Nix via nixfmt, shell via shfmt, Markdown/JSON/YAML via prettier, etc.).
Run 'nix fmt' (without --fail-on-change) to fix the files in place, then
re-run this command."
run nix fmt -- --fail-on-change

if [[ ${1:-} == "--with-builds" ]]; then
  section "Light build/invariant suite" \
    "Builds the deploy checks, security/persistence invariants, sops
bootstrap fixtures, and library tests that don't require hardware or
secrets. A failure here points at a specific check name — open
flake/checks.nix or the named test under tests/ to see what it asserts."
  run bash scripts/validate.sh light

  section "Sample inventory data build" \
    "Builds the inventory-data package (the generator that produces the
sanitized inventory JSON). A failure here means the generator itself
(lib/hosts.nix or the inventory-json app) is broken — not that the committed
docs/samples/inventory.sample.json has drifted from live output."
  run bash scripts/validate.sh package inventory-data
fi

echo
echo "Doctor: all checks passed. This tree is healthy from a clean clone."
