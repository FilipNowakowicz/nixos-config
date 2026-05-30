#!/usr/bin/env bash
set -euo pipefail

system="${SYSTEM:-x86_64-linux}"

repo_root="$(
  git rev-parse --show-toplevel 2>/dev/null || pwd
)"

cd "$repo_root"

build_attrs() {
  if [[ ${PRINT_PATHS:-} == "1" ]]; then
    nix build "$@" --no-link --print-out-paths --show-trace
  else
    nix build "$@" --no-link --show-trace
  fi
}

show_report_attrs() {
  local output
  while IFS= read -r output; do
    cat "$output"
    printf '\n'
  done < <(nix build "$@" --no-link --print-out-paths --show-trace)
}

usage() {
  cat <<EOF
Usage: $0 <command>

Commands:
  docs               Check repository Markdown links
  flake-eval         Run flake evaluation only (no builds)
  light              Build lightweight blocking checks
  host <name>        Build one host closure: main-ci, main, homeserver-gcp, mac
  hosts              Build all host system closures used in CI
  package <name>     Build one package output used in CI
  profile-test <name>
                     Build one profile test: profile-security, profile-observability, profile-hardening
  smoke-homeserver-gcp
                     Build the homeserver-gcp endpoint smoke test
  profile-tests      Build all profile NixOS tests
  heavy              Build all smoke and profile tests
  cve-reports        Build and print the CVE report outputs
EOF
}

command="${1:-}"
target="${2:-}"

build_host() {
  case "$1" in
  main-ci)
    build_attrs ".#nixosConfigurations.main-ci.config.system.build.toplevel"
    ;;
  main | main-full)
    build_attrs ".#nixosConfigurations.main.config.system.build.toplevel"
    ;;
  homeserver-gcp)
    build_attrs ".#nixosConfigurations.homeserver-gcp.config.system.build.toplevel"
    ;;
  mac)
    build_attrs ".#nixosConfigurations.mac.config.system.build.toplevel"
    ;;
  *)
    echo "Unknown host target: $1" >&2
    exit 1
    ;;
  esac
}

build_profile_test() {
  case "$1" in
  profile-security)
    build_attrs ".#legacyPackages.${system}.ciTests.profile-security"
    ;;
  profile-observability)
    build_attrs ".#legacyPackages.${system}.ciTests.profile-observability"
    ;;
  profile-hardening)
    build_attrs ".#legacyPackages.${system}.ciTests.profile-hardening"
    ;;
  *)
    echo "Unknown profile test target: $1" >&2
    exit 1
    ;;
  esac
}

build_package() {
  case "$1" in
  inventory-data)
    build_attrs ".#packages.${system}.inventory-data"
    ;;
  *)
    echo "Unknown package target: $1" >&2
    exit 1
    ;;
  esac
}

case "$command" in
docs)
  bash scripts/check-doc-links.sh
  ;;

flake-eval)
  nix flake check --no-build --show-trace
  ;;

light)
  # The pre-commit derivation is intentionally excluded from CI: its hooks
  # (statix, deadnix, treefmt, shellcheck, secrets-directory) are already
  # covered by the lint job and the secrets-directory check below. The
  # plaintext-secrets scan unique to pre-commit runs in the lint job.
  build_attrs \
    ".#checks.${system}.deploy-activate" \
    ".#checks.${system}.deploy-schema" \
    ".#checks.${system}.homeserver-gcp-sops-bootstrap" \
    ".#checks.${system}.invariants-homeserver-gcp" \
    ".#checks.${system}.invariants-main" \
    ".#checks.${system}.invariants-main-ci" \
    ".#checks.${system}.invariants-mac" \
    ".#checks.${system}.lib-generators" \
    ".#checks.${system}.lib-generators-structured" \
    ".#checks.${system}.lib-acl" \
    ".#checks.${system}.lib-invariants" \
    ".#checks.${system}.mac-sops-bootstrap" \
    ".#checks.${system}.secrets-directory" \
    ".#checks.${system}.lib-scan-plaintext-secrets"
  ;;

host)
  build_host "${target:?Usage: $0 host <name>}"
  ;;

package)
  build_package "${target:?Usage: $0 package <name>}"
  ;;

hosts)
  build_attrs \
    ".#nixosConfigurations.main-ci.config.system.build.toplevel" \
    ".#nixosConfigurations.homeserver-gcp.config.system.build.toplevel" \
    ".#nixosConfigurations.mac.config.system.build.toplevel"
  ;;

smoke-homeserver-gcp)
  build_attrs ".#legacyPackages.${system}.ciTests.homeserver-gcp-smoke"
  ;;

profile-test)
  build_profile_test "${target:?Usage: $0 profile-test <name>}"
  ;;

profile-tests)
  build_attrs \
    ".#legacyPackages.${system}.ciTests.profile-security" \
    ".#legacyPackages.${system}.ciTests.profile-observability" \
    ".#legacyPackages.${system}.ciTests.profile-hardening"
  ;;

heavy)
  build_attrs \
    ".#legacyPackages.${system}.ciTests.homeserver-gcp-smoke" \
    ".#legacyPackages.${system}.ciTests.profile-security" \
    ".#legacyPackages.${system}.ciTests.profile-observability" \
    ".#legacyPackages.${system}.ciTests.profile-hardening"
  ;;

cve-reports)
  show_report_attrs \
    ".#legacyPackages.${system}.ciReports.main" \
    ".#legacyPackages.${system}.ciReports.homeserver-gcp"
  ;;

"" | -h | --help | help)
  usage
  ;;

*)
  echo "Unknown command: $command" >&2
  echo >&2
  usage >&2
  exit 1
  ;;
esac
