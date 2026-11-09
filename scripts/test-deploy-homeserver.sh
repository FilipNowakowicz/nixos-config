#!/usr/bin/env bash
# Static wiring plus a stubbed no-op: never contacts a host or activates anything.
set -euo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
workflow=.github/workflows/deploy-homeserver.yml
grep -qF 'branches: [main]' "$workflow"
grep -qF 'workflow_dispatch:' "$workflow"
grep -qF 'cancel-in-progress: false' "$workflow"
[[ $(grep -c 'runs-on: ubuntu-latest' "$workflow") == 2 ]]
if grep -q 'self-hosted\|validation_scope\|continue-on-error' "$workflow"; then
  echo "Unsafe deployment runner or bypass found" >&2
  exit 1
fi
[[ $(grep -c "require('./scripts/check-deploy-merge-gate.cjs')" "$workflow") == 2 ]]
grep -qF 'needs: builder' "$workflow"
grep -qF 'tags: tag:ci' "$workflow"
grep -qF 'scripts/on-builder.sh' "$workflow"
grep -qF -- '--max-jobs 0 --builders' scripts/deploy-homeserver.sh
grep -qF '.remoteBuild = false' scripts/deploy-homeserver-build.sh
grep -qF '.profiles.system.drvPath =' scripts/deploy-homeserver-build.sh
grep -q 'nix-store -qR .*derivation' scripts/deploy-homeserver-build.sh
grep -qF 'path = builtins.appendContext profile.path' scripts/deploy-homeserver.sh
node scripts/test-deploy-merge-gate.cjs

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/bundle"
export TEST_SYSTEM=/nix/store/00000000000000000000000000000000-system
export TEST_SSH_CALLS="$tmp/ssh-calls"
printf '#!%s\n' "$(command -v bash)" >"$tmp/bin/ssh"
cat >>"$tmp/bin/ssh" <<'STUB'
set -euo pipefail
[[ ${*: -1} == 'readlink -f /run/current-system' ]]
echo readlink >> "$TEST_SSH_CALLS"
echo "$TEST_SYSTEM"
STUB
chmod +x "$tmp/bin/ssh"
jq -n --arg system "$TEST_SYSTEM" '{system: $system,
  client: "/nix/store/00000000000000000000000000000000-must-not-run", deploy: {nodes: {"homeserver-gcp": {
    hostname: "test.invalid", sshUser: "user", remoteBuild: false, magicRollback: true, autoRollback: true
  }}}}' >"$tmp/bundle/bundle.json"
PATH="$tmp/bin:$PATH" bash scripts/deploy-homeserver.sh "$tmp/bundle" >"$tmp/result"
grep -q 'no activation required' "$tmp/result"
[[ $(wc -l <"$TEST_SSH_CALLS") == 1 ]]
[[ ! -f $tmp/bundle/flake.nix ]]
echo 'Deployment workflow and unchanged-closure contracts passed'
