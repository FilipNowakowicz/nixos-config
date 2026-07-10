#!/usr/bin/env bash
set -euo pipefail

repo_root="$(
  git rev-parse --show-toplevel 2>/dev/null || pwd
)"
cd "$repo_root"

usage() {
  cat <<'EOF'
Usage: bash scripts/check-host-drift.sh [host]

Compare a host's live state against the repo's expected drift facts.

Examples:
  bash scripts/check-host-drift.sh main
  bash scripts/check-host-drift.sh homeserver-gcp
EOF
}

host="${1:-}"

# Detect current hostname once; reused as default target and for transport decisions.
current_host=""
if command -v hostnamectl >/dev/null 2>&1; then
  current_host="$(hostnamectl --static 2>/dev/null || true)"
fi
if [[ -z $current_host ]]; then
  current_host="$(hostname -s 2>/dev/null || true)"
fi

if [[ -z $host ]]; then
  host="$current_host"
fi

case "${host:-}" in
"" | -h | --help | help)
  usage
  exit 0
  ;;
esac

if [[ -n ${HOST_DRIFT_INVENTORY_JSON:-} ]]; then
  inventory_path="$HOST_DRIFT_INVENTORY_JSON"
else
  inventory_attr="${HOST_DRIFT_INVENTORY_ATTR:-.#packages.x86_64-linux.drift-inventory-data}"
  inventory_path="$(nix build "$inventory_attr" --no-link --print-out-paths)/inventory.json"
fi

host_json="$(
  jq -e -c --arg host "$host" '.hosts[] | select(.name == $host)' "$inventory_path"
)"

{
  read -r expected_tag
  read -r expected_fqdn
  read -r strict_tcp_port_set
  read -r deployable
  read -r deploy_user
  read -r expected_ports_json
  read -r expected_extra_ports_json
} < <(jq -r '
  .drift.tailscaleTag // "",
  .drift.tailnetFQDN // "",
  (.drift.strictTCPPortSet // false | tostring),
  (.deployable // false | tostring),
  .deployUser // "",
  (.drift.tcpPorts // [] | tojson),
  (.drift.expectedExtraTCPPorts // [] | tojson)
' <<<"$host_json")
mapfile -t units < <(jq -r '.drift.systemdUnits // [] | .[]' <<<"$host_json")

transport="local"
transport_target="$host"
if [[ $deployable == "true" && $host != "$current_host" ]]; then
  if [[ -z $deploy_user || -z $expected_fqdn ]]; then
    echo "error: ${host} is deployable but inventory data does not include ssh user and tailnet FQDN" >&2
    exit 1
  fi
  transport="ssh"
  transport_target="${deploy_user}@${expected_fqdn}"
fi
if [[ $deployable != "true" && -n $current_host && $host != "$current_host" ]]; then
  echo "error: ${host} is a local-only host; run this command on ${host} itself" >&2
  exit 1
fi

# shellcheck disable=SC2016
probe_script='
set -euo pipefail

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

if command -v tailscale >/dev/null 2>&1; then
  tailscale status --json >"$tmpdir/tailscale.json" 2>/dev/null || printf "{}\n" >"$tmpdir/tailscale.json"
else
  printf "{}\n" >"$tmpdir/tailscale.json"
fi

if command -v ss >/dev/null 2>&1; then
  if ! ss -H -ltn >"$tmpdir/ports.txt" 2>/dev/null; then
    : >"$tmpdir/ports.txt"
  fi
else
  : >"$tmpdir/ports.txt"
fi

: >"$tmpdir/units.txt"
for unit in "$@"; do
  state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  if [ -z "$state" ]; then
    state="unknown"
  fi
  printf "%s\t%s\n" "$unit" "$state" >>"$tmpdir/units.txt"
done

emit_section() {
  local name="$1"
  local path="$2"
  printf "__HOST_DRIFT_SECTION__ %s %s\n" "$name" "$(base64 <"$path" | tr -d "\n")"
}

emit_section tailscale "$tmpdir/tailscale.json"
emit_section ports "$tmpdir/ports.txt"
emit_section units "$tmpdir/units.txt"
'

echo "Building expected drift data for ${host}..."

# A drift-check run immediately follows deploy-rs's activation confirmation,
# which only proves systemd accepted the new units, not that every service
# has finished its own startup work (e.g. AdGuardHome loading filter lists
# before it binds :53). Retry a few times before failing so that race does
# not flake CI; a host still drifted after these retries is a real failure.
max_attempts=5
retry_delay_seconds=3
attempt=1
failures=()

while true; do
  echo "Collecting live state over ${transport}: ${transport_target} (attempt ${attempt}/${max_attempts})"

  probe_output=""
  if [[ $transport == "ssh" ]]; then
    probe_output="$(
      ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        "$transport_target" \
        bash -s -- "${units[@]}" <<<"$probe_script"
    )"
  else
    probe_output="$(
      bash -s -- "${units[@]}" <<<"$probe_script"
    )"
  fi

  section_b64() {
    local name="$1"
    awk -v name="$name" '$1 == "__HOST_DRIFT_SECTION__" && $2 == name { print $3 }' <<<"$probe_output"
  }

  tailscale_json="$(section_b64 tailscale | base64 -d)"
  ports_text="$(section_b64 ports | base64 -d)"
  units_text="$(section_b64 units | base64 -d)"

  actual_tags_json="$(jq -c '[.Self.Tags[]? | sub("^tag:"; "")] | unique' <<<"$tailscale_json")"
  actual_fqdn="$(jq -r '(.Self.DNSName // "") | rtrimstr(".")' <<<"$tailscale_json")"
  # The host's own tailnet IPs. tailscaled binds dynamic WireGuard sockets here on
  # ephemeral high ports that change every restart, so they can never be expressed
  # as a static expected-port set; drop any listener bound to a tailnet IP.
  ts_self_ips_json="$(jq -c '[.Self.TailscaleIPs[]? // empty]' <<<"$tailscale_json")"
  actual_ports_json="$(
    awk '
      $1 == "LISTEN" {
        local = $4
        # Split "addr:port": the port follows the final colon, the rest is the
        # bind address (IPv6 addresses arrive bracketed, e.g. [fd7a::1]:22000).
        port = local
        sub(/^.*:/, "", port)
        addr = local
        sub(/:[^:]*$/, "", addr)
        gsub(/^\[|\]$/, "", addr)
        if (port ~ /^[0-9]+$/) print addr "\t" port
      }
    ' <<<"$ports_text" | jq -Rcs --argjson tsips "$ts_self_ips_json" '
      [ split("\n")[]
        | select(length > 0)
        | (split("\t")) as $f
        | { addr: $f[0], port: ($f[1] | tonumber) }
        | select(.addr != "127.0.0.1" and .addr != "::1")
        | select((.addr | IN($tsips[])) | not)
        | .port
      ]
      | unique
    '
  )"

  failures=()

  record_failure() {
    local message="$1"
    failures+=("$message")
  }

  if [[ -n $expected_tag ]]; then
    if ! jq -e --arg tag "$expected_tag" 'index($tag) != null' <<<"$actual_tags_json" >/dev/null; then
      live_tags="$(jq -r 'if length == 0 then "<none>" else join(", ") end' <<<"$actual_tags_json")"
      record_failure "tailscale tag mismatch: expected ${expected_tag} from lib/hosts.nix, live tags are ${live_tags}"
    fi
  fi

  if [[ -n $expected_fqdn && $actual_fqdn != "$expected_fqdn" ]]; then
    record_failure "tailnet FQDN mismatch: expected ${expected_fqdn} from lib/hosts.nix, live value is ${actual_fqdn:-<missing>}"
  fi

  missing_ports_json="$(
    jq -nc \
      --argjson expected "$expected_ports_json" \
      --argjson actual "$actual_ports_json" \
      '$expected - $actual'
  )"
  if [[ "$(jq 'length' <<<"$missing_ports_json")" -gt 0 ]]; then
    record_failure "missing listening TCP ports: expected $(jq -r 'join(", ")' <<<"$missing_ports_json") from networking.firewall.interfaces.tailscale0.allowedTCPPorts"
  fi

  if [[ $strict_tcp_port_set == "true" ]]; then
    extra_ports_json="$(
      jq -nc \
        --argjson expected "$expected_ports_json" \
        --argjson allowed "$expected_extra_ports_json" \
        --argjson actual "$actual_ports_json" \
        '$actual - $expected - $allowed'
    )"
    if [[ "$(jq 'length' <<<"$extra_ports_json")" -gt 0 ]]; then
      record_failure "unexpected non-loopback listening TCP ports: $(jq -r 'join(", ")' <<<"$extra_ports_json"); add to drift.expectedExtraTCPPorts if intended, else review host service modules or manual changes"
    fi
  fi

  while IFS=$'\t' read -r unit state; do
    [[ -n $unit ]] || continue
    if [[ $state != "active" ]]; then
      record_failure "systemd unit ${unit} is ${state}; expected active because the corresponding service is enabled in NixOS modules"
    fi
  done <<<"$units_text"

  if [[ ${#failures[@]} -eq 0 ]]; then
    echo "Host drift check passed for ${host}."
    exit 0
  fi

  if [[ $attempt -ge $max_attempts ]]; then
    break
  fi

  echo "Drift detected on attempt ${attempt}/${max_attempts} for ${host} (may be a post-activation startup race); retrying in ${retry_delay_seconds}s:"
  for failure in "${failures[@]}"; do
    echo "  - ${failure}"
  done
  sleep "$retry_delay_seconds"
  attempt=$((attempt + 1))
done

echo "HOST DRIFT DETECTED for ${host}:"
for failure in "${failures[@]}"; do
  echo "  - ${failure}"
done
exit 1
