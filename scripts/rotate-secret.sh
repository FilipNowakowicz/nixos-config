#!/usr/bin/env bash
set -euo pipefail

# rotate-secret.sh — the newline-safe envelope around sops secret rotation.
#
# This bottles the two traps that have bitten this repo before (see the rotation
# ritual in docs/security.md):
#   1. `sops --set` fed via `$(cat key)` strips the value's trailing newline, so
#      OpenSSH later rejects the key. We set values byte-for-byte via `jq -Rs`.
#   2. treefmt reformats secrets.yaml, turning the lint gate red. We run
#      `nix fmt` on the touched file as part of the rotation.
# Every mutating command re-verifies the stored value round-trips exactly
# (`sops -d --output-type json | jq -j`) before returning.
#
# It deliberately does NOT generate provider-issued secrets (Tailscale auth
# keys, Backblaze B2 keys, GitHub PATs, webhook URLs) or auto-deploy. Those
# steps are inherently manual and are documented in docs/security.md.

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/rotate-secret.sh set      <file> <key>            # value from stdin (byte-exact, newline preserved)
  bash scripts/rotate-secret.sh random   <file> <key> [len]      # generate a random alnum secret (default 48)
  bash scripts/rotate-secret.sh password <file> <key> [method]   # prompt + mkpasswd hash (default yescrypt)
  bash scripts/rotate-secret.sh sshkey   <file> <key> [comment]  # generate an ed25519 key, print the public half
  bash scripts/rotate-secret.sh observability                    # rotate the telemetry ingest password across main+mac+homeserver

Examples:
  printf '%s' "$NEW_PAT" | bash scripts/rotate-secret.sh set hosts/homeserver-gcp/secrets/secrets.yaml github_runner_homeserver_deploy_token
  bash scripts/rotate-secret.sh random   hosts/homeserver-gcp/secrets/secrets.yaml grafana_secret_key
  bash scripts/rotate-secret.sh password hosts/main/secrets/secrets.yaml user_password
  bash scripts/rotate-secret.sh sshkey   hosts/main/secrets/secrets.yaml initrd_ssh_host_ed25519_key

CAUTION — these are NOT a blind swap (see docs/security.md):
  restic_password      rotate against the repo with `restic key add/remove`, or you lose old snapshots.
  grafana_secret_key   re-encrypts Grafana datasource secrets; rotate via Grafana, not just here.
  host SSH/age keys     require `sops updatekeys` + .sops.yaml changes; out of scope for this helper.
EOF
}

die() {
  echo "rotate-secret: $*" >&2
  exit 1
}

require_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "missing '$t' on PATH (run inside 'nix develop')"
  done
}

# Set a top-level string key in a sops file to the exact bytes of $src.
# jq -Rs encodes the whole file verbatim (trailing newline included) as a JSON
# string, so no `$(cat)`-style newline stripping can occur.
sops_set_from_file() {
  local file=$1 key=$2 src=$3 value_json
  value_json=$(jq -Rs . <"$src")
  sops --set "[\"$key\"] $value_json" "$file"
}

# Decrypt the stored value to $dst as raw bytes. JSON output + `jq -j` reproduce
# the string exactly with no display newline, so a cmp against the source is
# authoritative.
sops_get_to_file() {
  local file=$1 key=$2 dst=$3
  sops -d --output-type json "$file" | jq -j --arg k "$key" '.[$k]' >"$dst"
}

# Mutate one key: set from $src, format, verify byte-exact round-trip.
rotate_one() {
  local file=$1 key=$2 src=$3
  [[ -f $file ]] || die "no such secrets file: $file"
  sops_set_from_file "$file" "$key" "$src"
  nix fmt "$file" >/dev/null 2>&1 || die "nix fmt failed on $file"
  local got
  got=$(mktemp)
  sops_get_to_file "$file" "$key" "$got"
  if ! cmp -s "$src" "$got"; then
    rm -f "$got"
    die "round-trip verify FAILED for [$key] in $file (stored value != intended bytes)"
  fi
  rm -f "$got"
  echo "✓ $file [$key] rotated and verified"
}

cmd_set() {
  local file=${1:-} key=${2:-}
  [[ -n $file && -n $key ]] || die "usage: set <file> <key>  (value on stdin)"
  require_tools sops jq nix
  local src
  src=$(mktemp)
  cat >"$src" # raw stdin, byte-exact (trailing newline preserved if present)
  [[ -s $src ]] || die "empty value on stdin; aborting"
  rotate_one "$file" "$key" "$src"
  rm -f "$src"
  next_steps "$file"
}

cmd_random() {
  local file=${1:-} key=${2:-} len=${3:-48}
  [[ -n $file && -n $key ]] || die "usage: random <file> <key> [len]"
  require_tools sops jq nix base64
  local src
  src=$(mktemp)
  # alnum-only so the value is safe in env files / URLs; no trailing newline.
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len" >"$src"
  printf '\n  generated %s-char random secret\n' "$len" >&2
  rotate_one "$file" "$key" "$src"
  rm -f "$src"
  next_steps "$file"
}

cmd_password() {
  local file=${1:-} key=${2:-} method=${3:-yescrypt}
  [[ -n $file && -n $key ]] || die "usage: password <file> <key> [method]"
  require_tools sops jq nix mkpasswd
  local pw pw2 hash src
  read -rsp "New password: " pw && echo
  read -rsp "Confirm: " pw2 && echo
  [[ -n $pw ]] || die "empty password; aborting"
  [[ $pw == "$pw2" ]] || die "passwords do not match"
  hash=$(printf '%s' "$pw" | mkpasswd -m "$method" --stdin)
  src=$(mktemp)
  printf '%s' "$hash" >"$src" # hash only, no trailing newline
  rotate_one "$file" "$key" "$src"
  rm -f "$src"
  next_steps "$file"
}

cmd_sshkey() {
  local file=${1:-} key=${2:-} comment=${3:-rotated-$(date +%Y%m%d)}
  [[ -n $file && -n $key ]] || die "usage: sshkey <file> <key> [comment]"
  require_tools sops jq nix ssh-keygen
  local dir
  dir=$(mktemp -d)
  ssh-keygen -t ed25519 -N "" -C "$comment" -f "$dir/key" >/dev/null
  # The private key file keeps OpenSSH's trailing newline, which we preserve.
  rotate_one "$file" "$key" "$dir/key"
  echo
  echo "Public half (wire this into the consuming nix config / authorized_keys):"
  cat "$dir/key.pub"
  rm -rf "$dir"
  next_steps "$file"
}

# The telemetry ingest credential is split: main+mac hold the raw password,
# homeserver-gcp holds its htpasswd line. Rotating one side without the other
# silently breaks authenticated metric/log/trace push, so do all three at once.
cmd_observability() {
  require_tools sops jq nix mkpasswd base64
  local user=telemetry
  local main=hosts/main/secrets/secrets.yaml
  local mac=hosts/mac/secrets/secrets.yaml
  local hs=hosts/homeserver-gcp/secrets/secrets.yaml
  local f
  for f in "$main" "$mac" "$hs"; do [[ -f $f ]] || die "missing $f"; done

  local pw src_pw src_ht
  pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)
  src_pw=$(mktemp)
  printf '%s' "$pw" >"$src_pw"
  src_ht=$(mktemp)
  printf '%s:%s\n' "$user" "$(printf '%s' "$pw" | mkpasswd -m bcrypt --stdin)" >"$src_ht"

  rotate_one "$main" observability_ingest_password "$src_pw"
  rotate_one "$mac" observability_ingest_password "$src_pw"
  rotate_one "$hs" observability_ingest_htpasswd "$src_ht"
  rm -f "$src_pw" "$src_ht"

  echo
  echo "All three files updated with a new '$user' ingest credential. Next:"
  echo "  - homeserver-gcp: commit + push (auto-deploys via .github/workflows/deploy-homeserver.yml)"
  echo "  - main:           rebuild"
  echo "  - mac:            deploy '.#mac'"
  echo "  Deploy homeserver-gcp BEFORE main/mac so the new htpasswd is live when clients switch."
}

next_steps() {
  local file=$1
  echo
  echo "Next: review 'git diff -- $file', commit, then deploy the owning host:"
  case $file in
  hosts/homeserver-gcp/*) echo "  homeserver-gcp auto-deploys on push to main (path-filtered)." ;;
  hosts/main/*) echo "  main: rebuild" ;;
  hosts/mac/*) echo "  mac: deploy '.#mac'  (or local 'nh os switch --hostname mac .')" ;;
  home/*) echo "  user scope: home-manager switch / rebuild as appropriate." ;;
  esac
}

main() {
  local sub=${1:-}
  shift || true
  case $sub in
  set) cmd_set "$@" ;;
  random) cmd_random "$@" ;;
  password) cmd_password "$@" ;;
  sshkey) cmd_sshkey "$@" ;;
  observability) cmd_observability "$@" ;;
  -h | --help | "") usage ;;
  *) die "unknown command '$sub' (try --help)" ;;
  esac
}

main "$@"
