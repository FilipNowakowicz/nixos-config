#!/usr/bin/env bash
# Use an imported, finished closure; never evaluate the repository during activation.
set -euo pipefail
bundle=${1:?Usage: deploy-homeserver.sh <bundle directory>}
bundle=$(realpath "$bundle")
node=$(jq -cer '.deploy.nodes["homeserver-gcp"]' "$bundle/bundle.json")
host=$(jq -er '.hostname' <<<"$node")
user=$(jq -er '.sshUser' <<<"$node")
system=$(jq -er '.system' "$bundle/bundle.json")
client=$(jq -er '.client' "$bundle/bundle.json")
jq -e '.remoteBuild == false and .magicRollback == true and .autoRollback == true' <<<"$node" >/dev/null
[[ $system =~ ^/nix/store/[a-z0-9]{32}-[^/]+$ ]]
[[ $client =~ ^/nix/store/[a-z0-9]{32}-[^/]+$ ]]
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
target="$user@$host"
current=$(ssh "${ssh_opts[@]}" "$target" 'readlink -f /run/current-system')
if [[ $current == "$system" ]]; then
  echo 'Homeserver closure unchanged; no activation required.'
  exit 0
fi
# A tiny input-free flake makes deploy-rs use the already imported store path.
jq '.deploy' "$bundle/bundle.json" >"$bundle/deploy.json"
cat >"$bundle/flake.nix" <<'NIX'
{
  outputs = _:
    let
      data = builtins.fromJSON (builtins.readFile ./deploy.json);
      node = data.nodes.homeserver-gcp;
      profile = node.profiles.system;
    in
    {
      deploy.nodes.homeserver-gcp = node // {
        profiles.system = profile // {
          # JSON loses Nix string context. Restore a plain store-path context,
          # never a derivation, so nix build can reuse the imported output.
          path = builtins.appendContext profile.path {
            "${profile.path}" = { path = true; };
          };
        };
      };
    };
}
NIX
"$client/bin/deploy" --skip-checks "path:$bundle#homeserver-gcp" -- --max-jobs 0 --builders ''
actual=$(ssh "${ssh_opts[@]}" "$target" 'readlink -f /run/current-system')
[[ $actual == "$system" ]] || {
  echo 'Activated system does not match the built closure.' >&2
  exit 1
}
# Read inventory from the activated host rather than building one on this runner.
ssh "${ssh_opts[@]}" "$target" 'cat /etc/host-drift-inventory.json' >"$bundle/inventory.json"
HOST_DRIFT_INVENTORY_JSON="$bundle/inventory.json" bash scripts/check-host-drift.sh homeserver-gcp
ssh "${ssh_opts[@]}" "$target" 'bash -se' <scripts/check-homeserver-health.sh
