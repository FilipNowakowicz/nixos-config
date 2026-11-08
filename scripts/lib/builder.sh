# shellcheck shell=bash disable=SC2034
# Shared helpers for reaching the on-demand gcp-builder VM. Sourced by
# scripts/validate.sh, scripts/on-builder.sh and scripts/rebuild-remote.sh.

builder_name="gcp-builder"
builder_zone="${BUILDER_ZONE:-europe-west2-a}"
builder_fqdn="${BUILDER_FQDN:-}"
builder_key="${BUILDER_SSH_KEY:-/run/secrets/gcp_builder_build_key}" # root-owned on main; daemon reads it
builder_maxjobs="${BUILDER_MAXJOBS:-8}"
builder_features="kvm,nixos-test,big-parallel,benchmark"
gcloud_cmd=()

# Only hosts with the build key deployed use the builder, so CI and fresh clones
# keep working locally.
builder_enabled() {
  [[ ${USE_BUILDER:-1} != 0 ]] || return 1
  [[ -e $builder_key ]] || return 1
}

# gcp-agent does not carry the Google Cloud SDK as a base package.
resolve_gcloud_cmd() {
  if command -v gcloud >/dev/null 2>&1; then
    gcloud_cmd=(gcloud)
  elif command -v nix >/dev/null 2>&1; then
    gcloud_cmd=(nix shell nixpkgs#google-cloud-sdk -c gcloud)
  else
    return 1
  fi
}

# The registry's FQDN, through the deploy-rs output; BUILDER_FQDN overrides it.
resolve_builder_fqdn() {
  [[ -n $builder_fqdn ]] && return 0
  builder_fqdn="$(nix eval --raw .#deploy.nodes.gcp-builder.hostname 2>/dev/null || true)"
  if [[ -z $builder_fqdn ]]; then
    builder_fqdn="gcp-builder.tail90fc7a.ts.net"
  fi
}

builder_ssh_opts() {
  # gcp-agent has no personal key and uses its build key. On main that file is
  # unreadable, and ssh skips it and uses the caller's own key.
  printf '%s\n' -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 \
    -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=no -i "$builder_key"
}

# Start the VM (a no-op if it is running) and wait until it accepts SSH.
start_builder() {
  local opts ready=0
  mapfile -t opts < <(builder_ssh_opts)
  resolve_gcloud_cmd || {
    echo "remote builder: gcloud is not available" >&2
    return 1
  }
  resolve_builder_fqdn
  echo "remote builder: starting $builder_name ..." >&2
  if ! "${gcloud_cmd[@]}" compute instances start "$builder_name" --zone "$builder_zone" --quiet >/dev/null 2>&1; then
    echo "remote builder: could not start the VM (check gcloud project and login)" >&2
    return 1
  fi
  for _ in $(seq 1 40); do
    if ssh "${opts[@]}" "user@$builder_fqdn" true 2>/dev/null; then
      ready=1
      break
    fi
    sleep 3
  done
  if [[ $ready != 1 ]]; then
    echo "remote builder: not reachable over SSH" >&2
    return 1
  fi
  echo "remote builder: $builder_name ready" >&2
}
