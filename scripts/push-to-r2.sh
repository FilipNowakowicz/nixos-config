#!/usr/bin/env bash
# Push build outputs to the R2 binary cache.
# Usage: push-to-r2.sh [<validate.sh args...>]
# Env: R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, CACHE_SIGNING_KEY
set -euo pipefail

: "${R2_ACCESS_KEY_ID:?}"
: "${R2_SECRET_ACCESS_KEY:?}"
: "${CACHE_SIGNING_KEY:?}"

system="${SYSTEM:-x86_64-linux}"

KEY_FILE="$(mktemp)"
trap 'rm -f "$KEY_FILE"' EXIT
printf '%s' "$CACHE_SIGNING_KEY" >"$KEY_FILE"

R2_STORE="s3://nix-cache?endpoint=https://89d783d5aa24b5311bc8564fa7602456.r2.cloudflarestorage.com&region=auto&secret-key=$KEY_FILE"

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"

script_dir="$(cd "$(dirname "$0")" && pwd)"

if [[ -n ${PATHS_FILE:-} ]]; then
  if [[ ! -f ${PATHS_FILE} ]]; then
    echo "PATHS_FILE does not exist: ${PATHS_FILE}" >&2
    exit 1
  fi
  mapfile -t paths <"$PATHS_FILE"
else
  mapfile -t paths < <(PRINT_PATHS=1 bash "$script_dir/validate.sh" "$@")
fi

if [[ ${#paths[@]} -eq 0 ]]; then
  echo "No paths to push." >&2
  exit 0
fi

# Allowlist of expected derivation names: narrows "anything `nix path-info`
# recognizes" (any store path reachable from a `main`-mergeable build) down to
# this flake's own host closures, packages, and CI checks/tests. Derived live
# from the flake's own outputs (not hand-maintained), so it can't drift from
# `scripts/validate.sh`'s `light`/`host`/`package`/`tests` attribute sets.
flake_dir="$(cd "$script_dir/.." && pwd)"

collect_drv_names() {
  nix eval --json "$flake_dir#$1" \
    --apply 'attrs: builtins.attrValues (builtins.mapAttrs (_: v: v.name) attrs)' 2>/dev/null |
    jq -r '.[]'
}

mapfile -t allowed_names < <(
  {
    collect_drv_names "checks.${system}"
    collect_drv_names "packages.${system}"
    collect_drv_names "legacyPackages.${system}.ciTests"
    nix eval --json "$flake_dir#nixosConfigurations" \
      --apply 'attrs: builtins.attrValues (builtins.mapAttrs (_: v: v.config.system.build.toplevel.name) attrs)' 2>/dev/null |
      jq -r '.[]'
  } | sort -u
)

is_allowed_name() {
  local name="$1" candidate
  for candidate in "${allowed_names[@]}"; do
    [[ $name == "$candidate" ]] && return 0
  done
  return 1
}

validated_paths=()
for path in "${paths[@]}"; do
  if [[ $path != /nix/store/* ]]; then
    echo "Refusing to push non-store path: ${path:-<empty>}" >&2
    exit 1
  fi

  if ! nix path-info "$path" >/dev/null; then
    echo "Refusing to push unknown store path: $path" >&2
    exit 1
  fi

  drv_name="${path#/nix/store/*-}"
  if ! is_allowed_name "$drv_name"; then
    echo "Refusing to push path with unexpected derivation name: $path" >&2
    exit 1
  fi

  validated_paths+=("$path")
done

echo "Pushing ${#validated_paths[@]} path(s) to R2..."
nix copy --to "$R2_STORE" -- "${validated_paths[@]}"
