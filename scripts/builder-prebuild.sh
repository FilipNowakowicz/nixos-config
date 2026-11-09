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

# Tell the private ntfy topic how the run ended. Best effort: the status file is
# the record, and a builder reprovisioned without the URL file simply stays quiet.
notify_result() {
  local url_file=$state_dir/notify-url result_now short_rev title body priority=default
  [[ -r $url_file ]] || return 0
  result_now=$(jq -r '.result // "failed"' "$state_dir/status.json")
  short_rev=$(jq -r '.revision // "" | .[0:7]' "$state_dir/status.json")
  if [[ $result_now == success ]]; then
    title="System update ready"
    body="Prebuilt main at $short_rev. Apply it with: rebuild --prebuilt"
  else
    title="System update failed"
    body=$(jq -r '.error // "see journalctl -u builder-prebuild"' "$state_dir/status.json")
    priority=high
  fi
  curl --fail --silent --show-error --max-time 10 --retry 2 --retry-delay 2 \
    -H "Title: $title" -H "Priority: $priority" --data-binary "$body" \
    "$(<"$url_file")" >/dev/null || echo "could not send prebuild notification" >&2
}

# ExecStopPost: runs after every run, whatever its result.
if [[ ${1:-} == --service-failed ]]; then
  # systemd also publishes failure after a timeout or forced termination. EXIT
  # already published an actionable ordinary failure, so do not replace
  # missing-source instructions with a generic systemd exit-code message.
  if [[ ${SERVICE_RESULT:-success} != success ]] &&
    ! { [[ ${SERVICE_RESULT:-} == exit-code ]] &&
      jq -e '.result == "missing-displaylink" or .result == "failed"' "$state_dir/status.json" >/dev/null 2>&1; }; then
    revision=$(jq -r '.revision // ""' "$state_dir/status.json" 2>/dev/null || true)
    result=failed
    [[ ${SERVICE_RESULT:-} != timeout ]] || result=timeout
    error="systemd service result: ${SERVICE_RESULT:-unknown}; see journalctl -u builder-prebuild"
    write_status
  fi
  notify_result
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
