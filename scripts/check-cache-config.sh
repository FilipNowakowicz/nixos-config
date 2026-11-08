#!/usr/bin/env bash
set -euo pipefail

repo_root="$(
  git rev-parse --show-toplevel 2>/dev/null || pwd
)"
cd "$repo_root"

extract_first_match() {
  local pattern=$1
  local file=$2

  if command -v rg >/dev/null 2>&1; then
    rg -o "$pattern" "$file" | head -n 1
  else
    grep -Eo "$pattern" "$file" | head -n 1
  fi
}

setup_cache_url="$(extract_first_match 'https://nix\.cloudsmith\.io/[^[:space:]]+' .github/actions/setup-nix/action.yml)"
shared_cache_url="$(extract_first_match 'https://nix\.cloudsmith\.io/[^"]+' lib/binary-cache.nix)"

setup_cache_key="$(
  sed -n 's/.*trusted-public-keys = .* \(nixos-nix-cache-[0-9]*:[^[:space:]]*\).*/\1/p' \
    .github/actions/setup-nix/action.yml |
    head -n 1
)"
shared_cache_key="$(
  sed -n 's/.*"\(nixos-nix-cache-[0-9]*:[^"]*\)".*/\1/p' lib/binary-cache.nix | head -n 1
)"

if [[ -z $setup_cache_url || -z $shared_cache_url || -z $setup_cache_key || -z $shared_cache_key ]]; then
  echo "Unable to extract cache configuration from setup-nix or lib/binary-cache.nix." >&2
  exit 1
fi

if [[ $setup_cache_url != "$shared_cache_url" ]]; then
  echo "Cache URL mismatch:" >&2
  echo "  setup-nix:        $setup_cache_url" >&2
  echo "  lib/binary-cache: $shared_cache_url" >&2
  exit 1
fi

if [[ $setup_cache_key != "$shared_cache_key" ]]; then
  echo "Cache public key mismatch:" >&2
  echo "  setup-nix:        $setup_cache_key" >&2
  echo "  lib/binary-cache: $shared_cache_key" >&2
  exit 1
fi

echo "cache config matches"
