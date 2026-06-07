#!/usr/bin/env bash
set -euo pipefail

# Applies the rendered Tailscale ACL artifact (lib/acl.nix) to the live tailnet
# policy without clobbering live-only sections (ssh, autoApprovers, nodeAttrs,
# groups, ...). The rendered artifact only carries {tagOwners, acls} — POSTing
# it as-is would replace the *entire* policy file and silently wipe everything
# else. Instead this fetches the live policy, overlays only .tagOwners and
# .acls from the rendered artifact, and POSTs the merged result back — guarded
# by the live policy's ETag so a concurrent edit aborts the apply rather than
# racing it.
#
# Required env:
#   TAILSCALE_API_KEY   — Tailscale API key with ACL read+write access
#   TAILSCALE_TAILNET   — Tailscale tailnet name (e.g. tail90fc7a.ts.net)
#
# Usage:
#   bash scripts/apply-tailscale-acl.sh [--dry-run]

: "${TAILSCALE_API_KEY:?TAILSCALE_API_KEY must be set}"
: "${TAILSCALE_TAILNET:?TAILSCALE_TAILNET must be set}"

dry_run=0
case "${1:-}" in
--dry-run) dry_run=1 ;;
"") ;;
*)
  echo "usage: $0 [--dry-run]" >&2
  exit 2
  ;;
esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

api_url="https://api.tailscale.com/api/v2/tailnet/${TAILSCALE_TAILNET}/acl"
headers_file="$(mktemp)"
trap 'rm -f "$headers_file"' EXIT

echo "Building rendered ACL artifact..."
acl_path="$(nix build '.#packages.x86_64-linux.tailscale-acl' --no-link --print-out-paths)"
rendered_json="$(<"$acl_path")"

echo "Fetching live Tailscale policy..."
live_json="$(
  curl -sf \
    --header "Authorization: Bearer ${TAILSCALE_API_KEY}" \
    --header "Accept: application/json" \
    --dump-header "$headers_file" \
    "$api_url"
)"

# The ETag lets the POST below use If-Match so Tailscale rejects the write if
# the live policy changed between this GET and the apply (out-of-band edit).
etag="$(tr -d '\r' <"$headers_file" | awk -F': ' 'tolower($1) == "etag" { print $2 }')"

live_normal="$(jq -S '{tagOwners, acls}' <<<"$live_json")"
rendered_normal="$(jq -S '{tagOwners, acls}' <<<"$rendered_json")"

if [[ $live_normal == "$rendered_normal" ]]; then
  echo "No drift: live policy already matches the rendered artifact. Nothing to apply."
  exit 0
fi

echo ""
echo "tagOwners/acls diff (live -> rendered):"
diff --unified \
  --label "live (${TAILSCALE_TAILNET})" \
  <(printf '%s\n' "$live_normal") \
  --label "rendered (lib/acl.nix)" \
  <(printf '%s\n' "$rendered_normal") || true

if [[ $dry_run == 1 ]]; then
  echo ""
  echo "Dry run: not applying. Re-run without --dry-run to apply the merged policy."
  exit 0
fi

# Shallow-merge: keep every live top-level key (ssh, autoApprovers, nodeAttrs,
# groups, ...) and override only tagOwners/acls with the rendered values. A
# deep merge (jq's `*`) would instead union live and rendered tag keys, leaving
# stale live-only tags behind.
merged_json="$(
  jq -n --argjson live "$live_json" --argjson rendered "$rendered_json" \
    '$live + { tagOwners: $rendered.tagOwners, acls: $rendered.acls }'
)"

post_args=(
  --header "Authorization: Bearer ${TAILSCALE_API_KEY}"
  --header "Content-Type: application/json"
)
if [[ -n $etag ]]; then
  post_args+=(--header "If-Match: ${etag}")
fi

echo ""
echo "Applying merged policy (live sections outside tagOwners/acls preserved)..."
curl -sf "${post_args[@]}" \
  --data "$merged_json" \
  "$api_url" >/dev/null

echo "Applied. Re-run scripts/check-tailscale-acl-drift.sh to confirm drift is gone."
