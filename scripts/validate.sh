#!/usr/bin/env bash
set -euo pipefail

system="${SYSTEM:-x86_64-linux}"

repo_root="$(
  git rev-parse --show-toplevel 2>/dev/null || pwd
)"

cd "$repo_root"

# ── On-demand remote builder ─────────────────────────────────────────────────
# Heavy build commands transparently offload to the on-demand gcp-builder VM:
# start it (idempotent), wait for SSH over Tailscale, then pass --builders for
# the invocation. The builder powers itself off when idle. This is a no-op
# (local build) whenever offload is disabled, gcloud is unavailable, or the
# build key is absent — e.g. in CI or before `main` has the wiring deployed.
builder_name="gcp-builder"
builder_zone="${BUILDER_ZONE:-europe-west2-a}"
builder_fqdn="${BUILDER_FQDN:-}"
builder_key="/run/secrets/gcp_builder_build_key" # root-owned; daemon reads it
builder_maxjobs="${BUILDER_MAXJOBS:-8}"
builder_features="kvm,nixos-test,big-parallel,benchmark"
builder_nix_args=()

builder_enabled() {
  [[ ${USE_BUILDER:-1} != 0 ]] || return 1
  command -v gcloud >/dev/null 2>&1 || return 1
  [[ -e $builder_key ]] || return 1 # only present on a deployed `main`
}

# Resolve the builder FQDN from the deploy-rs flake output (sourced from the
# host registry's tailnetFQDN), falling back to the historical literal if
# `nix eval` fails. BUILDER_FQDN still overrides both.
resolve_builder_fqdn() {
  [[ -n $builder_fqdn ]] && return 0
  builder_fqdn="$(nix eval --raw .#deploy.nodes.gcp-builder.hostname 2>/dev/null || true)"
  if [[ -z $builder_fqdn ]]; then
    builder_fqdn="gcp-builder.tail90fc7a.ts.net"
  fi
}

ensure_builder() {
  builder_enabled || {
    echo "remote builder: disabled (USE_BUILDER=0, no gcloud, or no build key); building locally" >&2
    return 0
  }
  resolve_builder_fqdn
  echo "remote builder: starting $builder_name ..." >&2
  if ! gcloud compute instances start "$builder_name" --zone "$builder_zone" --quiet >/dev/null 2>&1; then
    echo "remote builder: could not start VM (check gcloud project/auth); building locally" >&2
    return 0
  fi
  # Readiness probe uses the caller's own SSH key (authorized via sops-base);
  # the build itself uses the root-only build key path under --builders.
  local ready=0
  for _ in $(seq 1 40); do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      "user@$builder_fqdn" true 2>/dev/null; then
      ready=1
      break
    fi
    sleep 3
  done
  if [[ $ready != 1 ]]; then
    echo "remote builder: not reachable after wait; building locally" >&2
    return 0
  fi
  builder_nix_args=(
    --builders
    "ssh-ng://user@$builder_fqdn x86_64-linux $builder_key $builder_maxjobs 2 $builder_features"
  )
  echo "remote builder: $builder_name ready; offloading builds" >&2
}

build_attrs() {
  if [[ ${PRINT_PATHS:-} == "1" ]]; then
    nix build "$@" ${builder_nix_args[@]+"${builder_nix_args[@]}"} --no-link --print-out-paths --show-trace
  else
    nix build "$@" ${builder_nix_args[@]+"${builder_nix_args[@]}"} --no-link --show-trace
  fi
}

show_report_attrs() {
  local output paths_file rc=0
  paths_file="$(mktemp)"
  # Capture nix-build's exit status: process substitution does not propagate it
  # to the shell, so a failed build would otherwise be silently swallowed.
  nix build "$@" ${builder_nix_args[@]+"${builder_nix_args[@]}"} --no-link --print-out-paths --show-trace >"$paths_file" || rc=$?
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
  host <name>        Build one host closure: main-ci, main, homeserver-gcp, mac, installer
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
    # used for local deploys and the post-merge R2 cache-priming step in
    # .github/workflows/nix.yml.
    build_attrs ".#nixosConfigurations.main.config.system.build.toplevel"
    ;;
  homeserver-gcp)
    build_attrs ".#nixosConfigurations.homeserver-gcp.config.system.build.toplevel"
    ;;
  gcp-builder)
    build_attrs ".#nixosConfigurations.gcp-builder.config.system.build.toplevel"
    ;;
  gcp-agent)
    build_attrs ".#nixosConfigurations.gcp-agent.config.system.build.toplevel"
    ;;
  mac)
    build_attrs ".#nixosConfigurations.mac.config.system.build.toplevel"
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
      ".#packages.${system}.control-center" \
      ".#packages.${system}.tailscale-acl" \
      ".#packages.${system}.installer-iso"
    ;;
  inventory-data)
    build_attrs ".#packages.${system}.inventory-data"
    ;;
  control-center)
    build_attrs ".#packages.${system}.control-center"
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
  bash scripts/check-doc-links.sh
  bash scripts/agent-run-issue.sh --self-test
  bash scripts/agent-session.sh --self-test
  bash .agents/scripts/agent-record-outcome --self-test
  bash .agents/scripts/agent-outcome-index --self-test
  bash .agents/scripts/agent-weekly-digest --self-test
  bash .agents/scripts/agent-issue-readiness --self-test
  bash .agents/scripts/agent-liveness-gate --self-test
  bash .agents/scripts/agent-policy-eval --self-test
  bash .agents/scripts/agent-review-evidence-check --self-test
  bash .agents/scripts/agent-review-stage --self-test
  bash .agents/scripts/agent-routing-check --self-test
  bash .agents/scripts/agent-dispatch --self-test
  bash .agents/scripts/agent-dispatchable-issues --self-test
  bash .agents/scripts/agent-route --self-test
  bash .claude/hooks/guard-agent-dirty-checkout.sh --self-test
  bash scripts/check-ci-closure-targets.sh
  bash scripts/check-ci-closure-targets.sh --self-test
  bash .agents/learning/scripts/validate-candidates.sh
  bash .agents/repo-map/scripts/validate.sh
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
    ".#checks.${system}.gcp-agent-sops-bootstrap" \
    ".#checks.${system}.homeserver-gcp-sops-bootstrap" \
    ".#checks.${system}.invariants-gcp-agent" \
    ".#checks.${system}.invariants-gcp-builder" \
    ".#checks.${system}.invariants-homeserver-gcp" \
    ".#checks.${system}.invariants-main" \
    ".#checks.${system}.invariants-main-ci" \
    ".#checks.${system}.invariants-mac" \
    ".#checks.${system}.lib-doctor" \
    ".#checks.${system}.lib-generators" \
    ".#checks.${system}.lib-generators-structured" \
    ".#checks.${system}.lib-acl" \
    ".#checks.${system}.lib-invariants" \
    ".#checks.${system}.lib-mini-fleet-flake" \
    ".#checks.${system}.mac-sops-bootstrap" \
    ".#checks.${system}.observability-alerts-lint" \
    ".#checks.${system}.secrets-directory" \
    ".#checks.${system}.lib-scan-plaintext-secrets"
  ;;

host)
  ensure_builder
  build_host "${target:?Usage: $0 host <name>}"
  ;;

package)
  build_package "${target:?Usage: $0 package <name>}"
  ;;

hosts)
  ensure_builder
  build_attrs \
    ".#nixosConfigurations.main-ci.config.system.build.toplevel" \
    ".#nixosConfigurations.homeserver-gcp.config.system.build.toplevel" \
    ".#nixosConfigurations.gcp-builder.config.system.build.toplevel" \
    ".#nixosConfigurations.gcp-agent.config.system.build.toplevel" \
    ".#nixosConfigurations.mac.config.system.build.toplevel" \
    ".#packages.${system}.installer-iso"
  ;;

smoke-homeserver-gcp)
  if [[ ! -e /dev/kvm ]]; then
    echo "KVM not available: /dev/kvm missing; skipping homeserver-gcp smoke test." >&2
    exit 0
  fi
  ensure_builder
  build_attrs ".#legacyPackages.${system}.ciTests.homeserver-gcp-smoke"
  ;;

profile-test)
  ensure_builder
  build_profile_test "${target:?Usage: $0 profile-test <name>}"
  ;;

profile-tests)
  ensure_builder
  build_attrs \
    ".#legacyPackages.${system}.ciTests.profile-security" \
    ".#legacyPackages.${system}.ciTests.profile-observability" \
    ".#legacyPackages.${system}.ciTests.profile-hardening"
  ;;

heavy)
  ensure_builder
  build_attrs \
    ".#legacyPackages.${system}.ciTests.homeserver-gcp-smoke" \
    ".#legacyPackages.${system}.ciTests.profile-security" \
    ".#legacyPackages.${system}.ciTests.profile-observability" \
    ".#legacyPackages.${system}.ciTests.profile-hardening"
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
