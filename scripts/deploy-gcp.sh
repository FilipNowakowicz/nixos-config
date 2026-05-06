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
SSH_HOST_KEY_B64=$(
  sops --decrypt --input-type binary --output-type binary \
    hosts/homeserver-gcp/secrets/ssh_host_ed25519_key.enc |
    base64 -w0
)

echo "==> Initialising OpenTofu..."
cd infra
tofu init -upgrade

echo "==> Applying bootstrap infrastructure..."
tofu apply \
  -var "bootstrap_ssh_public_key=${BOOTSTRAP_PUBKEY}" \
  -var "ssh_host_key_b64=${SSH_HOST_KEY_B64}" \
  "$@"

if ((is_destroy)); then
  echo ""
  echo "Bootstrap infrastructure destroyed."
  exit 0
fi

INSTANCE_IP="$(tofu output -raw instance_external_ip)"
cd ..

echo "==> Waiting for bootstrap SSH on ${INSTANCE_IP}..."
tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
  if [[ -n ${TEMP_SSH_AGENT_STARTED:-} && -n ${SSH_AGENT_PID:-} ]]; then
    ssh-agent -k >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
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
  :
else
  eval "$(ssh-agent -s)" >/dev/null
  TEMP_SSH_AGENT_STARTED=1
  ssh-add "$BOOTSTRAP_PRIVKEY_PATH" >/dev/null
fi

echo "==> Installing NixOS with nixos-anywhere..."
nixos-anywhere \
  --flake '.#homeserver-gcp' \
  -i "${BOOTSTRAP_PRIVKEY_PATH}" \
  --ssh-option "StrictHostKeyChecking=yes" \
  --ssh-option "UserKnownHostsFile=${known_hosts}" \
  "bootstrap@${INSTANCE_IP}"

echo ""
echo "Done. Next steps:"
echo "  1. Wait ~60s for first boot (sops activation + Tailscale join)"
echo "  2. Confirm VM is on the tailnet: tailscale status | grep homeserver-gcp"
echo "  3. Remove bootstrap metadata:"
echo "     $(cd infra && tofu output -raw ssh_host_key_removal_cmd 2>/dev/null || echo 'cd infra && tofu output ssh_host_key_removal_cmd')"
echo "  4. Fill in real secrets: sops hosts/homeserver-gcp/secrets/secrets.yaml"
echo "  5. Later updates: deploy '.#homeserver-gcp'"
