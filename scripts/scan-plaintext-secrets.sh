#!/usr/bin/env bash
# Scan tracked files for plaintext credentials. Mirrors the no-plaintext-secrets
# pre-commit hook, but operates on all tracked files instead of staged ones —
# intended for CI to catch anything that slipped past local hooks.
#
# Usage: scan-plaintext-secrets.sh
set -euo pipefail

# Resolve the shared pattern relative to this script before changing directory,
# so the single source of truth in scripts/lib/ stays authoritative even when
# the script runs from a different working tree (e.g. the Nix check fixtures).
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pattern="$(<"$script_dir/lib/plaintext-secret-pattern.txt")"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

allowlist_file=".plaintext-secrets-allowlist"

is_valid_secrets_path() {
  local path="$1"
  case "$path" in
  *.enc | *.age)
    return 0
    ;;
  *.yaml | *.yml)
    grep -Eq '^[[:space:]]*sops:' "$path"
    return
    ;;
  *)
    return 1
    ;;
  esac
}

is_allowlisted() {
  local path="$1"
  [[ -f $allowlist_file ]] || return 1
  while IFS= read -r line; do
    [[ -z $line || $line =~ ^[[:space:]]*# ]] && continue
    # shellcheck disable=SC2053
    if [[ $path == $line ]]; then
      return 0
    fi
  done <"$allowlist_file"
  return 1
}

has_failed=0
while IFS= read -r path; do
  [[ -z $path || ! -f $path ]] && continue

  case "$path" in
  hosts/*/secrets/*)
    if is_valid_secrets_path "$path"; then
      continue
    fi
    echo "Invalid file under hosts/*/secrets/*: $path" >&2
    echo "Allowed file types are .enc, .age, and SOPS-managed .yaml/.yml." >&2
    has_failed=1
    continue
    ;;
  esac

  case "$path" in
  *.enc | *.age | .sops.yaml | flake.lock | result | result-*)
    continue
    ;;
  esac

  if is_allowlisted "$path"; then
    continue
  fi

  if grep -Einq "$pattern" "$path"; then
    echo "Potential plaintext secret in: $path" >&2
    has_failed=1
  fi
done < <(git ls-files)

exit "$has_failed"
