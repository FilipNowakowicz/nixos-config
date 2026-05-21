#!/usr/bin/env bash
# Provision the homeserver-gcp VM in GCP, then install NixOS onto it.
#
# Usage:
#   bash scripts/deploy-gcp.sh             # plan + apply
#   bash scripts/deploy-gcp.sh -auto-approve
#   bash scripts/deploy-gcp.sh -destroy
#
# Requirements: run inside `nix develop` (provides sops, opentofu, nixos-anywhere, gcloud).
# Before first run: copy infra/terraform.tfvars.example to infra/terraform.tfvars
# and fill in your GCP project ID.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

is_destroy=0
for arg in "$@"; do
  if [[ $arg == "-destroy" ]]; then
    is_destroy=1
    break
  fi
done

BOOTSTRAP_PUBKEY_PATH="${GCP_BOOTSTRAP_SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
if [[ ! -f $BOOTSTRAP_PUBKEY_PATH ]]; then
  echo "error: bootstrap SSH public key not found: $BOOTSTRAP_PUBKEY_PATH" >&2
  echo "set GCP_BOOTSTRAP_SSH_PUBKEY=/path/to/key.pub or create ~/.ssh/id_ed25519.pub" >&2
  exit 1
fi

BOOTSTRAP_PUBKEY=$(<"$BOOTSTRAP_PUBKEY_PATH")
BOOTSTRAP_PRIVKEY_PATH="${GCP_BOOTSTRAP_SSH_KEY:-${BOOTSTRAP_PUBKEY_PATH%.pub}}"
if [[ ! -f $BOOTSTRAP_PRIVKEY_PATH ]]; then
  echo "error: bootstrap SSH private key not found: $BOOTSTRAP_PRIVKEY_PATH" >&2
  echo "set GCP_BOOTSTRAP_SSH_KEY=/path/to/key or keep the private key next to ${BOOTSTRAP_PUBKEY_PATH}" >&2
  exit 1
fi

echo "==> Decrypting SSH host key..."
tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
  if [[ -n ${TEMP_SSH_AGENT_STARTED:-} && -n ${SSH_AGENT_PID:-} ]]; then
    ssh-agent -k >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

HOST_KEY_PATH="${tmpdir}/ssh_host_ed25519_key"
HOST_KEY_PUB_PATH="${HOST_KEY_PATH}.pub"
sops --decrypt --input-type binary --output-type binary \
  hosts/homeserver-gcp/secrets/ssh_host_ed25519_key.enc >"$HOST_KEY_PATH"
chmod 600 "$HOST_KEY_PATH"
ssh-keygen -y -f "$HOST_KEY_PATH" >"$HOST_KEY_PUB_PATH"
chmod 644 "$HOST_KEY_PUB_PATH"
EXPECTED_HOST_KEY="$(awk '{print $1 " " $2}' "$HOST_KEY_PUB_PATH")"

echo "==> Initialising OpenTofu..."
cd infra
tofu init -upgrade

echo "==> Applying bootstrap infrastructure..."
tofu apply \
  -var "bootstrap_ssh_public_key=${BOOTSTRAP_PUBKEY}" \
  "$@"

if ((is_destroy)); then
  echo ""
  echo "Bootstrap infrastructure destroyed."
  exit 0
fi

INSTANCE_IP="$(tofu output -raw instance_external_ip)"
INSTANCE_NAME="$(tofu output -raw instance_name)"
INSTANCE_ZONE="$(tofu output -raw instance_zone)"
cd ..

echo "==> Waiting for bootstrap SSH on ${INSTANCE_IP}..."
known_hosts="$tmpdir/known_hosts"

for _attempt in {1..60}; do
  if ssh-keyscan -T 5 -t ed25519 "$INSTANCE_IP" >"$known_hosts" 2>/dev/null && [[ -s $known_hosts ]]; then
    break
  fi
  sleep 5
done

if [[ ! -s $known_hosts ]]; then
  echo "error: bootstrap VM did not expose an SSH host key at ${INSTANCE_IP}" >&2
  exit 1
fi

echo "==> Loading bootstrap SSH key..."
if ssh-add -l >/dev/null 2>&1; then
  # Key already in agent — don't pass -i to nixos-anywhere (it tries to copy
  # encrypted keys to a temp file, which fails without an interactive passphrase prompt).
  NIXOS_ANYWHERE_KEY_ARGS=()
else
  eval "$(ssh-agent -s)" >/dev/null
  TEMP_SSH_AGENT_STARTED=1
  ssh-add "$BOOTSTRAP_PRIVKEY_PATH" >/dev/null
  NIXOS_ANYWHERE_KEY_ARGS=()
fi

SSH_OPTS=(
  -o "StrictHostKeyChecking=yes"
  -o "UserKnownHostsFile=${known_hosts}"
)

echo "==> Installing expected SSH host key on bootstrap VM..."
ssh "${SSH_OPTS[@]}" "bootstrap@${INSTANCE_IP}" 'sudo bash -c '"'"'
  set -euo pipefail
  install -d -m 755 /etc/ssh
  umask 077
  cat > /etc/ssh/ssh_host_ed25519_key
  ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key > /etc/ssh/ssh_host_ed25519_key.pub
  chmod 600 /etc/ssh/ssh_host_ed25519_key
  chmod 644 /etc/ssh/ssh_host_ed25519_key.pub
  systemctl restart ssh || systemctl restart sshd
'"'"'' <"$HOST_KEY_PATH"

echo "==> Verifying expected SSH host key..."
: >"$known_hosts"
for _attempt in {1..30}; do
  if ssh-keyscan -T 5 -t ed25519 "$INSTANCE_IP" >"$known_hosts" 2>/dev/null && [[ -s $known_hosts ]]; then
    SCANNED_HOST_KEY="$(awk '$2 == "ssh-ed25519" {print $2 " " $3; exit}' "$known_hosts")"
    if [[ $SCANNED_HOST_KEY == "$EXPECTED_HOST_KEY" ]]; then
      break
    fi
  fi
  sleep 2
done

SCANNED_HOST_KEY="$(awk '$2 == "ssh-ed25519" {print $2 " " $3; exit}' "$known_hosts")"
if [[ $SCANNED_HOST_KEY != "$EXPECTED_HOST_KEY" ]]; then
  echo "error: bootstrap VM SSH host key does not match expected homeserver-gcp key" >&2
  echo "expected: ${EXPECTED_HOST_KEY}" >&2
  echo "scanned:  ${SCANNED_HOST_KEY:-<none>}" >&2
  exit 1
fi

extra_files="${tmpdir}/extra-files"
install -Dm600 "$HOST_KEY_PATH" "${extra_files}/etc/ssh/ssh_host_ed25519_key"
install -Dm644 "$HOST_KEY_PUB_PATH" "${extra_files}/etc/ssh/ssh_host_ed25519_key.pub"

echo "==> Installing NixOS with nixos-anywhere..."
nixos-anywhere \
  --flake '.#homeserver-gcp' \
  --extra-files "$extra_files" \
  "${NIXOS_ANYWHERE_KEY_ARGS[@]}" \
  --ssh-option "StrictHostKeyChecking=yes" \
  --ssh-option "UserKnownHostsFile=${known_hosts}" \
  "bootstrap@${INSTANCE_IP}"

echo "==> Removing bootstrap metadata..."
BOOTSTRAP_METADATA_KEYS=(
  "bootstrap-ssh-public-key"
  "startup-script"
  "ssh-host-key-b64"
)
for metadata_key in "${BOOTSTRAP_METADATA_KEYS[@]}"; do
  gcloud compute instances remove-metadata "$INSTANCE_NAME" \
    --zone="$INSTANCE_ZONE" \
    --keys="$metadata_key" >/dev/null || true
done

remaining_metadata_keys="$(
  gcloud compute instances describe "$INSTANCE_NAME" \
    --zone="$INSTANCE_ZONE" \
    --flatten='metadata.items[]' \
    --format='value(metadata.items.key)'
)"
for metadata_key in "${BOOTSTRAP_METADATA_KEYS[@]}"; do
  if grep -Fxq "$metadata_key" <<<"$remaining_metadata_keys"; then
    echo "error: bootstrap metadata key still present after cleanup: ${metadata_key}" >&2
    exit 1
  fi
done

echo ""
echo "Done. Next steps:"
echo "  1. Wait ~60s for first boot (sops activation + Tailscale join)"
echo "  2. Confirm VM is on the tailnet: tailscale status | grep homeserver-gcp"
echo "  3. Run drift check: bash scripts/check-host-drift.sh homeserver-gcp"
echo "  4. Fill in real secrets: sops hosts/homeserver-gcp/secrets/secrets.yaml"
echo "  5. Later updates: deploy '.#homeserver-gcp' && bash scripts/check-host-drift.sh homeserver-gcp"
