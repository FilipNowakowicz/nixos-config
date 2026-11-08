#!/usr/bin/env bash
# Scheduled public-main build. Run by builder-prebuild.service, never on main.
set -euo pipefail

state_dir=${STATE_DIRECTORY:-/var/lib/builder-prebuilt}
repo=github:FilipNowakowicz/nixos-config
revision=""
store_path=""
result=failed
error="build did not complete; see journalctl -u builder-prebuild"
mkdir -p "$state_dir"

write_status() {
  local temporary
  temporary=$(mktemp "$state_dir/status.XXXXXX")
  jq -n --arg revision "$revision" --arg store_path "$store_path" \
    --arg result "$result" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg error "$error" \
    '{revision:$revision,store_path:$store_path,result:$result,timestamp:$timestamp,error:$error}' >"$temporary"
  chmod 644 "$temporary"
  mv -f "$temporary" "$state_dir/status.json"
}

# systemd also publishes failure after a timeout or forced termination.
if [[ ${1:-} == --service-failed ]]; then
  if [[ ${SERVICE_RESULT:-success} != success ]]; then
    # EXIT already published an actionable ordinary failure. Do not replace
    # missing-source instructions with a generic systemd exit-code message.
    if [[ ${SERVICE_RESULT:-} == exit-code ]] &&
      jq -e '.result == "missing-displaylink" or .result == "failed"' "$state_dir/status.json" >/dev/null 2>&1; then
      exit 0
    fi
    revision=$(jq -r '.revision // ""' "$state_dir/status.json" 2>/dev/null || true)
    result=failed
    [[ ${SERVICE_RESULT:-} != timeout ]] || result=timeout
    error="systemd service result: ${SERVICE_RESULT:-unknown}; see journalctl -u builder-prebuild"
    write_status
  fi
  exit 0
fi

trap write_status EXIT
trap 'result=timeout; error="build interrupted or timed out"; exit 124' TERM
trap 'error="build interrupted"; exit 130' INT
result=building
error=""
write_status
result=failed
error="could not resolve latest public main revision"
revision=$(nix flake metadata --refresh --json "$repo/main" | jq -er '.locked.rev')
[[ $revision =~ ^[0-9a-f]{40}$ ]]
result=building
error=""
write_status
result=failed
flake="$repo/$revision"
error="could not evaluate DisplayLink source for $revision"
blob=$(nix eval --raw "$flake#nixosConfigurations.main.pkgs.displaylink.src")
if ! nix path-info "$blob" >/dev/null 2>&1; then
  result=missing-displaylink
  error="DisplayLink requireFile missing: $blob. Seed privately from the laptop store; see docs/remote-builder.md. No public download or cache upload is permitted."
  echo "$error" >&2
  exit 1
fi
# Root the manually seeded source as well as the finished system.
nix-store --add-root "$state_dir/displaylink-source" --indirect --realise "$blob" >/dev/null
error="full main build failed for $revision; see journalctl -u builder-prebuild"
nix build "$flake#nixosConfigurations.main.config.system.build.toplevel" \
  --no-write-lock-file --out-link "$state_dir/system"
store_path=$(readlink -f "$state_dir/system")
[[ $store_path =~ ^/nix/store/[a-z0-9]{32}-nixos-system-main- ]]
result=success
error=""
