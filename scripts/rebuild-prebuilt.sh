#!/usr/bin/env bash
# Activate the builder's completed weekly main closure without evaluating/building
# the local system. start_builder only evaluates the builder's deployment hostname.
# shellcheck disable=SC2154
set -euo pipefail

fail() {
  echo "rebuild --prebuilt: $*" >&2
  exit 1
}

(($# == 0)) || fail "does not accept additional arguments"
[[ $(hostname) == main ]] || fail "only supported on main"
CDPATH='' cd -- "$(git rev-parse --show-toplevel)"
# shellcheck source=scripts/lib/builder.sh disable=SC1091
source scripts/lib/builder.sh

expected_revision=$(git rev-parse --verify 'refs/remotes/origin/main^{commit}') || fail "fetch origin/main before using a prebuilt system"
start_builder
mapfile -t ssh_opts < <(builder_ssh_opts)
status=$(ssh "${ssh_opts[@]}" "user@$builder_fqdn" cat /var/lib/builder-prebuilt/status.json) || fail "could not read builder status; no system activated"

jq -e '
  type == "object" and
  (.revision | type == "string" and test("^[0-9a-f]{40}$")) and
  (.store_path | type == "string") and
  (.result | IN("success", "building", "failed", "missing-displaylink", "timeout")) and
  (.timestamp | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
  (.error | type == "string")
' <<<"$status" >/dev/null || fail "malformed builder status; no system activated"
result=$(jq -r .result <<<"$status")
[[ $result == success ]] || fail "builder result is $result; wait for a successful build (no system activated)"
revision=$(jq -r .revision <<<"$status")
[[ $revision == "$expected_revision" ]] || fail "builder revision $revision differs from origin/main $expected_revision; no system activated"
store_path=$(jq -r .store_path <<<"$status")
[[ $store_path =~ ^/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-nixos-system-main-[A-Za-z0-9.+_-]+$ ]] || fail "invalid main system store path; no system activated"

# This dedicated authenticated builder already has root-equivalent trust as a
# remote builder. Its outputs are unsigned; skip signatures only for this copy.
# Import before changing the boot profile or running activation.
nix copy --from "ssh-ng://user@$builder_fqdn" --no-check-sigs "$store_path"
[[ -x $store_path/bin/switch-to-configuration ]] || fail "copied system has no activation executable"
# Reject a changed local tracking ref after the copy as well.
[[ $(git rev-parse --verify 'refs/remotes/origin/main^{commit}') == "$revision" ]] || fail "origin/main changed during copy; no system activated"
sudo nix-env -p /nix/var/nix/profiles/system --set "$store_path"
sudo "$store_path/bin/switch-to-configuration" switch
