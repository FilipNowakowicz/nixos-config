#!/usr/bin/env bash
# Keep the public upstream cache intact and reject retired cache trust/publish wiring.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

upstream_key=$(sed -n 's/.*cacheNixosOrgPublicKey = "\([^"]*\)".*/\1/p' lib/binary-cache.nix)
[[ -n $upstream_key ]]
grep -qFx '          substituters = https://cache.nixos.org' .github/actions/setup-nix/action.yml
grep -qFx "          trusted-public-keys = $upstream_key" .github/actions/setup-nix/action.yml

if git grep -n -E 'r2\.dev|r2\.cloudflarestorage\.com|binaryCache\.r2|R2_ACCESS_KEY_ID|R2_SECRET_ACCESS_KEY|CACHE_SIGNING_KEY|push-to-r2|nix-cache-1:' -- \
  '*.nix' .github scripts ':!scripts/check-cache-config.sh'; then
  echo 'Retired binary cache configuration or publishing found.' >&2
  exit 1
fi
echo 'cache config: upstream preserved; retired cache absent'
