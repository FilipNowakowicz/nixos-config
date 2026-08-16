#!/usr/bin/env bash
# Promoted from: .agents/learning/candidates/2026-08-04-mullvad-cli-package-unit.yml
#
# nixpkgs stopped exposing bin/mullvad from pkgs.mullvad-vpn directly (only
# services.mullvad-vpn.package is guaranteed to carry the CLI); a custom
# systemd unit that shells out to "${pkgs.mullvad-vpn}/bin/mullvad" instead of
# "${config.services.mullvad-vpn.package}/bin/mullvad" fails at runtime with
# exit 127 (command not found), not at build time — see the mullvad-lockdown
# fix in hosts/main/networking.nix (PR #390). Statically reject any
# reintroduction of the raw-package spelling before it reaches a host.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

has_failed=0
while IFS= read -r path; do
  [[ -z $path || ! -f $path ]] && continue
  case "$path" in
  *.nix) ;;
  *) continue ;;
  esac

  if grep -nE '\$\{[[:space:]]*pkgs\.mullvad-vpn[[:space:]]*\}/bin/mullvad' "$path"; then
    echo "Use \${config.services.mullvad-vpn.package}/bin/mullvad, not \${pkgs.mullvad-vpn}/bin/mullvad, in: $path" >&2
    echo "(pkgs.mullvad-vpn does not reliably expose the CLI; services.mullvad-vpn.package does.)" >&2
    has_failed=1
  fi
done < <(git ls-files)

exit "$has_failed"
