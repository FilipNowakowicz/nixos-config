#!/usr/bin/env bash
# Publish audited free closure paths; credentials stay in CLOUDSMITH_API_KEY.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
nixpkgs="$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath')"
if [[ ${1:-} == --check ]]; then
  nix shell "path:$nixpkgs#uv" -c uv run --no-project --python 3.12 python tests/scripts/test_cloudsmith_policy.py
  exit
fi
: "${CLOUDSMITH_API_KEY:?}"
: "${PATHS_FILE:?}"
export CACHE_NIXPKGS_SOURCE="$nixpkgs"
nix shell "path:$nixpkgs#python3" "path:$nixpkgs#uv" -c python3 scripts/push-to-cloudsmith.py
