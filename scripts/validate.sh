#!/usr/bin/env bash
set -euo pipefail

system="${SYSTEM:-x86_64-linux}"

repo_root="$(
  git rev-parse --show-toplevel 2>/dev/null || pwd
)"

cd "$repo_root"

# ── On-demand remote builder ─────────────────────────────────────────────────
# On a host with the build key, heavy commands run entirely on the on-demand
# gcp-builder VM, including evaluation. If it cannot be reached they run here,
# after a warning. The VM powers itself off when idle.
# shellcheck source=scripts/lib/builder.sh disable=SC1091
source "$repo_root/scripts/lib/builder.sh"

offload_to_builder() {
  [[ ${ON_BUILDER:-0} == 0 ]] || return 0
  builder_enabled || return 0
  if ! start_builder; then
    echo "remote builder: UNAVAILABLE, running on this machine instead" >&2
    return 0
  fi
  BUILDER_READY=1 exec bash "$repo_root/scripts/on-builder.sh" bash scripts/validate.sh "$@"
}

build_attrs() {
  if [[ ${PRINT_PATHS:-} == "1" ]]; then
    nix build "$@" --no-link --print-out-paths --show-trace
  else
    nix build "$@" --no-link --show-trace
  fi
}

show_report_attrs() {
  local output paths_file rc=0
  paths_file="$(mktemp)"
  # Capture nix-build's exit status: process substitution does not propagate it
  # to the shell, so a failed build would otherwise be silently swallowed.
  nix build "$@" --no-link --print-out-paths --show-trace >"$paths_file" || rc=$?
  while IFS= read -r output; do
    cat "$output"
    printf '\n'
  done <"$paths_file"
  rm -f "$paths_file"
  return "$rc"
}

usage() {
  cat <<EOF
Usage: $0 <command>

Commands:
  docs               Check repository Markdown links
  flake-eval         Run flake evaluation only (no builds)
  light              Build lightweight blocking checks
  host <name>        Build one host closure: main-ci, main, homeserver-gcp, installer
  hosts              Build all host system closures used in CI
  package <name>     Build one package output used in CI, or package all
  profile-test <name>
                     Build one profile test: profile-security, profile-observability, profile-hardening
  smoke-homeserver-gcp
                     Build the homeserver-gcp endpoint smoke test
  profile-tests      Build all profile NixOS tests
  heavy              Build all smoke and profile tests
  cve-reports        Run vulnix CVE scan for each host (requires vulnix in PATH)
  tf-drift           Detect drift in infra/ against live GCP state (read-only plan)
EOF
}

command="${1:-}"
target="${2:-}"

case "$command" in
"" | -h | --help | docs | tf-drift | cve-reports) ;;
*) offload_to_builder "$@" ;;
esac

build_host() {
  case "$1" in
  main-ci)
    build_attrs ".#nixosConfigurations.main-ci.config.system.build.toplevel"
    ;;
  main | main-full)
    # Sanctioned exception: this is the only place the real `main` closure
    # (which pulls in the displaylink requireFile blob) may be referenced.
    # CI-required commands (hosts, light, cve-reports, package, etc.) must
    # build `main-ci` instead — enforced by
    # scripts/check-ci-closure-targets.sh. `host main`/`host main-full` is
    # used for local deploys.
    build_attrs ".#nixosConfigurations.main.config.system.build.toplevel"
    ;;
  homeserver-gcp)
    build_attrs ".#nixosConfigurations.homeserver-gcp.config.system.build.toplevel"
    ;;
  gcp-builder)
    build_attrs ".#nixosConfigurations.gcp-builder.config.system.build.toplevel"
    ;;
  installer)
    build_attrs ".#packages.${system}.installer-iso"
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
  profile-runtime-timezone)
    build_attrs ".#legacyPackages.${system}.ciTests.profile-runtime-timezone"
    ;;
  *)
    echo "Unknown profile test target: $1" >&2
    exit 1
    ;;
  esac
}

build_package() {
  case "$1" in
  all)
    build_attrs \
      ".#packages.${system}.inventory-data" \
      ".#packages.${system}.tailscale-acl" \
      ".#packages.${system}.installer-iso"
    ;;
  inventory-data)
    build_attrs ".#packages.${system}.inventory-data"
    ;;
  tailscale-acl)
    build_attrs ".#packages.${system}.tailscale-acl"
    ;;
  installer-iso)
    build_attrs ".#packages.${system}.installer-iso"
    ;;
  *)
    echo "Unknown package target: $1" >&2
    exit 1
    ;;
  esac
}

case "$command" in
docs)
  bash .agents/learning/promotions/quiet-shell-private-restart.sh
  bash scripts/check-doc-links.sh
  bash .agents/scripts/agent-issue-readiness --self-test
  bash .claude/hooks/guard-agent-dirty-checkout.sh --self-test
  bash scripts/check-ci-closure-targets.sh
  bash scripts/check-ci-closure-targets.sh --self-test
  bash .agents/learning/scripts/validate-candidates.sh
  bash .agents/learning/scripts/index-candidates.sh --self-test
  bash .agents/learning/scripts/scaffold-promotion-check.sh --self-test
  bash .agents/repo-map/scripts/validate.sh
  ;;

flake-eval)
  nix flake check --no-build --show-trace
  ;;

light)
  bash .agents/learning/promotions/bluetooth-boot-trigger.sh
  bash .agents/learning/promotions/mullvad-cli-package-unit.sh
  # The pre-commit derivation is intentionally excluded from CI: its hooks
  # (statix, deadnix, treefmt, shellcheck, secrets-directory) are already
  # covered by the lint job and the secrets-directory check below. The
  # plaintext-secrets scan unique to pre-commit runs in the lint job.
  build_attrs \
    ".#checks.${system}.deploy-activate" \
    ".#checks.${system}.deploy-schema" \
    ".#checks.${system}.homeserver-gcp-sops-bootstrap" \
    ".#checks.${system}.invariants-gcp-builder" \
    ".#checks.${system}.invariants-homeserver-gcp" \
    ".#checks.${system}.invariants-main" \
    ".#checks.${system}.invariants-main-ci" \
    ".#checks.${system}.invariants-registry-security" \
    ".#checks.${system}.invariants-installer" \
    ".#checks.${system}.lib-doctor" \
    ".#checks.${system}.lib-prebuilt" \
    ".#checks.${system}.lib-deploy-homeserver" \
    ".#checks.${system}.lib-on-builder" \
    ".#checks.${system}.lib-generators" \
    ".#checks.${system}.lib-generators-structured" \
    ".#checks.${system}.lib-acl" \
    ".#checks.${system}.lib-invariants" \
    ".#checks.${system}.lib-mini-fleet-flake" \
    ".#checks.${system}.observability-alerts-lint" \
    ".#checks.${system}.secrets-directory" \
    ".#checks.${system}.lib-scan-plaintext-secrets" \
    ".#checks.${system}.quiet-shell-status" \
    ".#checks.${system}.quiet-shell-search" \
    ".#checks.${system}.theme-module"
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
    ".#nixosConfigurations.gcp-builder.config.system.build.toplevel" \
    ".#packages.${system}.installer-iso"
  ;;

smoke-homeserver-gcp)
  if [[ ! -e /dev/kvm ]]; then
    echo "error: /dev/kvm missing; the homeserver-gcp smoke test cannot run here." >&2
    exit 1
  fi
  build_attrs ".#legacyPackages.${system}.ciTests.homeserver-gcp-smoke"
  ;;

smoke-quiet-shell)
  if [[ ! -e /dev/kvm ]]; then
    echo "error: /dev/kvm missing; the quiet-shell smoke test cannot run here." >&2
    exit 1
  fi
  build_attrs \
    ".#legacyPackages.${system}.ciTests.quiet-shell-smoke" \
    ".#legacyPackages.${system}.ciTests.desktop-session"
  ;;

profile-test)
  build_profile_test "${target:?Usage: $0 profile-test <name>}"
  ;;

profile-tests)
  build_attrs \
    ".#legacyPackages.${system}.ciTests.profile-security" \
    ".#legacyPackages.${system}.ciTests.profile-observability" \
    ".#legacyPackages.${system}.ciTests.profile-hardening" \
    ".#legacyPackages.${system}.ciTests.profile-runtime-timezone"
  ;;

heavy)
  build_attrs \
    ".#legacyPackages.${system}.ciTests.homeserver-gcp-smoke" \
    ".#legacyPackages.${system}.ciTests.quiet-shell-smoke" \
    ".#legacyPackages.${system}.ciTests.profile-security" \
    ".#legacyPackages.${system}.ciTests.profile-observability" \
    ".#legacyPackages.${system}.ciTests.profile-hardening" \
    ".#legacyPackages.${system}.ciTests.profile-runtime-timezone"
  ;;

cve-reports)
  # vulnix must be in PATH (dev shell provides it; CI wraps with nix shell).
  # Running vulnix inside a nix build derivation fails because the Nix daemon
  # rejects nix-store -qd connections from build processes.
  #
  # Scan `main-ci` rather than the real `main`: the real closure pulls in
  # pkgs.displaylink, a `requireFile` of an unfree Synaptics blob that CI can
  # neither fetch nor substitute (see modules/nixos/hardware/displaylink.nix),
  # so building it here fails the step before vulnix runs. `main-ci` sets
  # profiles.ci=true, which gates that blob out — the same CI-pure closure
  # merge-gate builds. The only packages this drops from the scan are the
  # ci-gated ones (displaylink, fprintd); vulnix cannot meaningfully CVE-match a
  # proprietary blob anyway.
  for spec in \
    "main-ci:.#nixosConfigurations.main-ci.config.system.build.toplevel" \
    "homeserver-gcp:.#nixosConfigurations.homeserver-gcp.config.system.build.toplevel"; do
    host="${spec%%:*}"
    attr="${spec#*:}"
    echo "=== CVE Scan for '$host' ==="
    closure=$(nix build --no-link --print-out-paths "$attr")
    if vulnix -R -j "$closure" 2>&1; then
      echo "VULNIX_ADVISORIES=0"
    else
      echo "VULNIX_ADVISORIES=1"
    fi
  done
  ;;

tf-drift)
  # Read-only drift guard for the manually-applied homeserver infra resources
  # (the deny-public-ssh firewall and snapshot policy carry "apply manually"
  # notes, so the live project can silently diverge from main).
  # -detailed-exitcode returns 2 when a plan has changes, surfaced here as drift.
  # Requires GCP credentials (ADC) + infra/terraform.tfvars, so it is a
  # manual/local check, not a CI gate.
  #
  # Scoped with -target to the homeserver host's resources on purpose: the
  # on-demand gcp-builder normally powers itself off, which nulls its ephemeral
  # external IP and would otherwise show as perpetual (benign) drift. We only
  # guard the always-on, security-relevant homeserver surface.
  #
  # bootstrap_ssh_public_key is required by variables.tf but only consumed at
  # first provisioning and held under lifecycle.ignore_changes, so a placeholder
  # produces no diff on the existing instance.
  if ! command -v tofu >/dev/null 2>&1; then
    echo "tf-drift: tofu not in PATH (run inside 'nix develop')" >&2
    exit 1
  fi
  tofu -chdir=infra init -input=false -upgrade >/dev/null
  set +e
  tofu -chdir=infra plan -input=false -detailed-exitcode -lock=false \
    -var "bootstrap_ssh_public_key=${BOOTSTRAP_PUBKEY:-tf-drift-placeholder-ignored}" \
    -target google_compute_instance.homeserver_gcp \
    -target google_compute_firewall.deny_public_ssh \
    -target google_compute_firewall.tailscale \
    -target google_compute_resource_policy.homeserver_boot_daily_snapshots \
    -target google_compute_disk_resource_policy_attachment.homeserver_boot_daily_snapshots
  rc=$?
  set -e
  case "$rc" in
  0) echo "tf-drift: no drift — live homeserver state matches infra/" ;;
  2)
    echo "tf-drift: DRIFT DETECTED — review the plan above" >&2
    exit 2
    ;;
  *)
    echo "tf-drift: tofu plan failed (rc=$rc)" >&2
    exit "$rc"
    ;;
  esac
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
