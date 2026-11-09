#!/usr/bin/env bash
# Runs only inside on-builder.sh's snapshot. Emit a complete prebuilt bundle.
set -euo pipefail
[[ ${ON_BUILDER:-0} == 1 ]]
git init -q
git add .
bash scripts/validate.sh flake-eval
PLAN_LIGHT=true PLAN_TESTS=true \
  PLAN_TESTS_MATRIX='{"include":[{"name":"homeserver-gcp-smoke","command":"smoke-homeserver-gcp","target":""}]}' \
  bash scripts/ci-builder-checks.sh
bash scripts/validate.sh host homeserver-gcp
activation=$(nix build .#deploy.nodes.homeserver-gcp.profiles.system.path --no-link --print-out-paths)
system=$(nix eval --raw .#nixosConfigurations.homeserver-gcp.config.system.build.toplevel.outPath)
client=$(nix build --impure --no-link --print-out-paths --expr \
  'let f = builtins.getFlake (toString ./.); in f.inputs.deploy-rs.packages.x86_64-linux.deploy-rs')
node=$(nix eval --json .#deploy.nodes.homeserver-gcp)
# Store paths become plain strings: the receiving runner has no derivations to build.
jq -n --argjson node "$node" --arg activation "$activation" \
  --arg system "$system" --arg client "$client" \
  '{system: $system, client: $client, deploy: {nodes: {"homeserver-gcp":
    ($node | .remoteBuild = false | .profiles.system.path = $activation)}}}' >bundle.json
# A GC root outlives this disposable checkout until the runner fetches the export.
# No credentials are copied to the builder. Stale bundles expire after one day.
mkdir -p "$HOME/deploy-bundles"
find "$HOME/deploy-bundles" -mindepth 1 -maxdepth 1 -type d -mmin +1440 -exec rm -rf {} +
bundle=$(mktemp -d "$HOME/deploy-bundles/bundle.XXXXXXXX")
nix-store --add-root "$bundle/activation" --indirect -r "$activation" >/dev/null
nix-store --add-root "$bundle/client" --indirect -r "$client" >/dev/null
cp bundle.json "$bundle/bundle.json"
mapfile -t paths < <(nix-store -qR "$activation" "$client")
nix-store --export "${paths[@]}" | zstd -T0 -3 >"$bundle/closure.nar.zst"
# Only this final line on stdout is consumed by the caller.
printf 'DEPLOY_BUNDLE=%s\n' "$bundle"
