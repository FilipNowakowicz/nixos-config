# shellcheck shell=bash disable=SC2034
# Shared helpers for reaching the on-demand gcp-builder VM. Sourced by
# scripts/validate.sh, scripts/on-builder.sh and scripts/rebuild-remote.sh.

builder_name="gcp-builder"
# Set BUILDER_ZONE to skip the lookup; start_builder otherwise finds the VM.
builder_zone="${BUILDER_ZONE:-}"
builder_zones=(europe-west2-a europe-west2-b europe-west2-c)
builder_machine_type="n2-standard-8"
builder_probe="gcp-builder-probe"
# Doubles as a lock: snapshot names are unique, so only one move can begin.
builder_snapshot="gcp-builder-move"
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

find_builder_zone() {
  local zone
  [[ -z $builder_zone ]] || return 0
  for zone in "${builder_zones[@]}"; do
    if "${gcloud_cmd[@]}" compute instances describe "$builder_name" --zone "$zone" \
      --format='value(name)' >/dev/null 2>&1; then
      builder_zone=$zone
      return 0
    fi
  done
  return 1
}

# Settings shared by the real VM and the capacity probe, so a successful probe
# also shows that CI's account may create this VM.
builder_instance_args() {
  printf '%s\n' --machine-type "$builder_machine_type" --enable-nested-virtualization \
    --network-interface network=default,subnet=default,network-tier=PREMIUM \
    --tags gcp-builder --metadata serial-port-enable=TRUE \
    --shielded-vtpm --shielded-integrity-monitoring --no-shielded-secure-boot \
    --resource-policies gcp-builder-weekly-prebuild \
    --no-service-account --no-scopes --maintenance-policy MIGRATE --restart-on-failure --quiet
}

# Google offers no capacity query, so create a throwaway VM and delete it.
zone_has_capacity() {
  local zone=$1 args rc=0
  mapfile -t args < <(builder_instance_args)
  "${gcloud_cmd[@]}" compute instances create "$builder_probe" --zone "$zone" "${args[@]}" \
    --image-family debian-12 --image-project debian-cloud \
    --boot-disk-size 10GB --boot-disk-type pd-standard >/dev/null 2>&1 || rc=$?
  "${gcloud_cmd[@]}" compute instances delete "$builder_probe" --zone "$zone" --quiet >/dev/null 2>&1 || true
  return "$rc"
}

first_zone_with_capacity() {
  local zone
  for zone in "${builder_zones[@]}"; do
    [[ $zone != "${1:-}" ]] || continue
    if zone_has_capacity "$zone"; then
      printf '%s\n' "$zone"
      return 0
    fi
  done
  return 1
}

place_builder() {
  local zone=$1 args
  mapfile -t args < <(builder_instance_args)
  "${gcloud_cmd[@]}" compute disks create "$builder_name" --zone "$zone" \
    --source-snapshot "$builder_snapshot" --type pd-balanced --size 100GB --quiet >/dev/null 2>&1 || return 1
  "${gcloud_cmd[@]}" compute instances create "$builder_name" --zone "$zone" "${args[@]}" \
    --disk "name=$builder_name,boot=yes,auto-delete=yes,device-name=persistent-disk-0,mode=rw" >/dev/null 2>&1 || return 1
  builder_zone=$zone
}

# The regional SSD quota cannot hold two copies of the disk, so the old VM goes
# before the new one exists. Capacity is checked first, and the snapshot is kept
# until the new VM answers, so a failure here can be resumed.
move_builder() {
  local target
  target=$(first_zone_with_capacity "$builder_zone") || {
    echo "remote builder: every zone is out of capacity" >&2
    return 1
  }
  echo "remote builder: $builder_zone is full, moving to $target (about 10 minutes) ..." >&2
  "${gcloud_cmd[@]}" compute disks snapshot "$builder_name" --zone "$builder_zone" \
    --snapshot-names "$builder_snapshot" --quiet >/dev/null 2>&1 || {
    echo "remote builder: could not snapshot the disk, or another move is running" >&2
    return 1
  }
  "${gcloud_cmd[@]}" compute instances delete "$builder_name" --zone "$builder_zone" \
    --delete-disks=all --quiet >/dev/null 2>&1 || return 1
  place_builder "$target"
}

# A VM that exists nowhere with an old snapshot means a move died partway. A
# recent snapshot may belong to a move still running, so leave that one alone.
resume_builder_move() {
  local created target
  created=$("${gcloud_cmd[@]}" compute snapshots describe "$builder_snapshot" \
    --format='value(creationTimestamp)' 2>/dev/null) || return 1
  (($(date +%s) - $(date -d "$created" +%s) > 1800)) || return 1
  target=$(first_zone_with_capacity) || return 1
  echo "remote builder: resuming an interrupted move to $target ..." >&2
  place_builder "$target"
}

# Start the VM (a no-op if it is running) and wait until it accepts SSH. If its
# zone has no capacity, move it to one that does.
start_builder() {
  local opts ready=0 moved=0 output
  mapfile -t opts < <(builder_ssh_opts)
  resolve_gcloud_cmd || {
    echo "remote builder: gcloud is not available" >&2
    return 1
  }
  resolve_builder_fqdn
  echo "remote builder: starting $builder_name ..." >&2
  if find_builder_zone; then
    if ! output=$("${gcloud_cmd[@]}" compute instances start "$builder_name" --zone "$builder_zone" --quiet 2>&1); then
      if [[ $output != *ZONE_RESOURCE_POOL_EXHAUSTED* ]]; then
        echo "remote builder: could not start the VM (check gcloud project and login)" >&2
        return 1
      fi
      move_builder || return 1
      moved=1
    fi
  else
    if ! resume_builder_move; then
      echo "remote builder: could not find the VM (check gcloud project and login)" >&2
      return 1
    fi
    moved=1
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
  if [[ $moved == 1 ]]; then
    "${gcloud_cmd[@]}" compute snapshots delete "$builder_snapshot" --quiet >/dev/null 2>&1 ||
      echo "remote builder: could not delete snapshot $builder_snapshot" >&2
  fi
  echo "remote builder: $builder_name ready" >&2
}
