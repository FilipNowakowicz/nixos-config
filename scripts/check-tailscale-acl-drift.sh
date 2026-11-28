#!/usr/bin/env bash
set -euo pipefail

# Compares the rendered tailscale-acl package against the live Tailscale policy.
# Only the fields emitted by our generator (tagOwners, acls and
# autoApprovers.exitNode) are compared after key-sorting so formatting noise
# does not trigger false positives. Other autoApprovers keys (routes) stay
# live-only.
#
# Required env:
#   TAILSCALE_API_KEY   — Tailscale API key with policy:read scope
#   TAILSCALE_TAILNET   — Tailscale tailnet name (e.g. tail90fc7a.ts.net)

: "${TAILSCALE_API_KEY:?TAILSCALE_API_KEY must be set}"
: "${TAILSCALE_TAILNET:?TAILSCALE_TAILNET must be set}"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

echo "Building rendered ACL artifact..."
acl_path="$(nix build '.#packages.x86_64-linux.tailscale-acl' --no-link --print-out-paths)"

echo "Fetching live Tailscale policy..."
# Print the HTTP status on failure: `curl -f` alone made an expired key look
# like a bare exit 22, and the scheduled check stayed red for seven weeks.
response="$(mktemp)"
trap 'rm -f "$response"' EXIT
status="$(
  curl -s -o "$response" -w '%{http_code}' \
    --header "Authorization: Bearer ${TAILSCALE_API_KEY}" \
    --header "Accept: application/json" \
    "https://api.tailscale.com/api/v2/tailnet/${TAILSCALE_TAILNET}/acl"
)"
if [[ $status != 200 ]]; then
  echo "Fetching the live policy failed: HTTP $status" >&2
  if [[ $status == 401 || $status == 403 ]]; then
    echo "TAILSCALE_API_KEY is likely expired or lacks policy:read; rotate it." >&2
  fi
  exit 1
fi
live_json="$(cat "$response")"

# Keep this filter in sync with scripts/apply-tailscale-acl.sh.
managed='{tagOwners, acls, exitNodeApprovers: ((.autoApprovers.exitNode // []) | sort)}'
rendered_normal="$(jq -S "$managed" "$acl_path")"
live_normal="$(printf '%s' "$live_json" | jq -S "$managed")"

if diff --unified \
  --label "rendered (lib/acl.nix)" \
  <(printf '%s\n' "$rendered_normal") \
  --label "live (${TAILSCALE_TAILNET})" \
  <(printf '%s\n' "$live_normal"); then
  echo "ACL drift check passed: live policy matches rendered artifact."
else
  echo ""
  echo "ACL DRIFT DETECTED: update lib/acl.nix or apply the rendered ACL to Tailscale."
  exit 1
fi
