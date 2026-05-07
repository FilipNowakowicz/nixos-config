# homeserver-gcp Host

GCP-hosted headless server. Runs Vaultwarden, LGTM stack, Syncthing, Tailscale, and Nginx.
No LUKS or impermanence (GCP handles at-rest encryption; state persists on the GCE disk).

Status: **active** — deployed on GCP, accessible via Tailscale.

## Services

- **Vaultwarden** — `127.0.0.1:8222`, proxied via Nginx over HTTPS
- **Syncthing** — peer-to-peer file sync
- **LGTM stack** — Grafana, Loki, Mimir, Tempo (full observability)
- **Nginx** — reverse proxy, TLS via Tailscale cert
- **SSH** — firewall exposure limited to `tailscale0`
- **Tailscale** — auth key from sops secret `tailscale_auth_key`
- **Restic/B2** — off-site backups to Backblaze B2

## Architecture

- **No LUKS** — GCP provides at-rest disk encryption automatically
- **No impermanence** — service state persists at `/var/lib/...` on the stateful GCE disk
- **GRUB bootloader** — via `virtualisation/google-compute-image.nix`
- **50 GB boot disk** — configured in `hardware-configuration.nix`

## Sops Bootstrap

Pre-baked host SSH key is committed encrypted to the repo.

- Private key: `hosts/homeserver-gcp/secrets/ssh_host_ed25519_key.enc`
- Public key: `hosts/homeserver-gcp/secrets/ssh_host_ed25519_key.pub.enc`
- Age identity: `&homeserver_gcp_host` in `.sops.yaml`

`nix build '.#checks.x86_64-linux.homeserver-gcp-sops-bootstrap'` verifies both files are present.

The pre-baked key must be injected into the VM before first boot so sops can decrypt
secrets (Tailscale auth key, passwords) on startup. See **First Deploy Checklist** below.

## Building the GCE Image

The `homeserver-gcp-image` package was removed because `google-compute-image.nix`
is not wired into the host config and the package broke `nix flake check`. The VM
is provisioned via `scripts/deploy-gcp.sh` (nixos-anywhere) and updated via
`deploy '.#homeserver-gcp'` — no image rebuild needed.

## First Deploy Checklist

Steps in order when reprovisioning from scratch:

1. **Fill in real secrets** — `sops hosts/homeserver-gcp/secrets/secrets.yaml`, set:
   - `tailscale_auth_key` — Tailscale admin → Settings → Keys → reusable + ephemeral
   - `user_password` — bcrypt hash: `mkpasswd -m bcrypt`
   - `grafana_admin_password`, `grafana_secret_key`, `observability_ingest_htpasswd`, `restic_password`

2. **Build and upload GCE image** — see above

3. **Provision VM** — use OpenTofu (see `infra/` when created); e2-medium, 50 GB SSD, region `us-central1`

4. **Inject pre-baked SSH host key** — the GCE image does NOT include the host key by default.
   Use a startup script or GCP serial console on first boot to write it:

   ```bash
   # Decrypt and write via gcloud (run from admin machine with age key):
   sops --decrypt --input-type binary --output-type binary \
     hosts/homeserver-gcp/secrets/ssh_host_ed25519_key.enc \
     > /tmp/host_key
   gcloud compute ssh homeserver-gcp --command "sudo install -m 600 /dev/stdin /etc/ssh/ssh_host_ed25519_key" < /tmp/host_key
   sudo systemctl restart sshd sops-install-secrets
   ```

   After this, sops can decrypt secrets and Tailscale joins the tailnet.

5. **Activate deploy-rs** — once the VM is on the tailnet:
   - Add `deploy.sshUser = "user"` is already in `lib/hosts.nix`
   - Deploy: `deploy '.#homeserver-gcp'`

6. **Create Vaultwarden account** — set `SIGNUPS_ALLOWED = true`, deploy, create account,
   set back to `false`, redeploy.

## Ongoing Updates

```bash
deploy '.#homeserver-gcp'
```

## Gotchas

- **sops fails on first boot if host key is not injected** — Tailscale won't join, SSH won't
  work over Tailscale. Use GCE serial console or `gcloud compute ssh` (uses GCP project keys)
  to recover.
- **TLS cert is not ACME** — `tailscale-cert.service` fetches it; nginx depends on that service.
- **Access is tailnet-only** — `tailscale0` is the only interface that permits inbound SSH/HTTPS.
- **Disk is stateful** — no impermanence. Data survives reboots naturally.
- **Off-site backup via B2** — restic backs up to Backblaze B2; see `modules/nixos/profiles/backup.nix`.
