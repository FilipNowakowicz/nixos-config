# homeserver-gcp Host

GCP-hosted headless server. Runs Vaultwarden, LGTM stack, Tailscale, and Nginx.
No LUKS or impermanence (GCP handles at-rest encryption; state persists on the GCE disk).

Status: **active** — deployed on GCP, accessible via Tailscale.

## Services

- **Vaultwarden** — `127.0.0.1:8222`, proxied via Nginx over HTTPS
- **LGTM stack** — Grafana (sub-path `/grafana/`, Tailscale identity via nginx auth proxy), Loki, Mimir, Tempo (full observability)
- **Nginx** — reverse proxy, TLS via Tailscale cert
- **SSH** — firewall exposure limited to `tailscale0`
- **Tailscale** — auth key from sops secret `tailscale_auth_key`
- **AdGuard Home** — DNS (TCP/UDP 53) + web UI (HTTP port 3001), tailscale0 only; state at `/var/lib/AdGuardHome`
- **Restic/B2** — off-site backups to Backblaze B2 (`/var/lib/vaultwarden`, `/var/lib/grafana`, `/var/lib/AdGuardHome`)
- **GCE snapshots** — daily 7-day boot disk snapshots for fast provider-local rollback

## Architecture

- **No LUKS** — GCP provides at-rest disk encryption automatically
- **No impermanence** — service state persists at `/var/lib/...` on the stateful GCE disk
- **systemd-boot** — UEFI bootloader (see `hardware-configuration.nix`)
- **50 GB boot disk** — partitioned by `disko.nix` (512 MB ESP + ext4 root taking the rest)

## Disk Layout

`homeserver-gcp` intentionally keeps a root-only data layout: `disko.nix` creates
one 512 MB EFI system partition and one ext4 root filesystem that consumes the
remaining GCE boot disk. There is no `/persist` volume and no reserved data
partition without an owner.

Keep this layout until a concrete operational need appears for isolated quotas
or retention, such as separating Loki, Mimir, or restic cache churn from the root
filesystem. If that happens, mount only the specific high-churn paths and update
the restore procedure alongside the partition change.

## Sops Bootstrap

Pre-baked host SSH key is committed encrypted to the repo.

- Private key: `hosts/homeserver-gcp/secrets/ssh_host_ed25519_key.enc`
- Public key: `hosts/homeserver-gcp/secrets/ssh_host_ed25519_key.pub.enc`
- Age identity: `&homeserver_gcp_host` in `.sops.yaml`

`nix build '.#checks.x86_64-linux.homeserver-gcp-sops-bootstrap'` verifies both files are present.

The pre-baked key is injected into the VM **automatically** on first boot:

1. `scripts/deploy-gcp.sh` decrypts the key and passes it to OpenTofu as `ssh_host_key_b64`.
2. OpenTofu (`infra/main.tf`) attaches it as the `ssh-host-key-b64` GCE instance metadata attribute.
3. The `injectGceSshHostKey` activation script in `default.nix` reads that metadata over the GCE metadata server before sops-nix runs and installs it at `/etc/ssh/ssh_host_ed25519_key`.

No manual key injection step is needed.

## Provisioning

Provisioning is end-to-end automated via `scripts/deploy-gcp.sh`:

```bash
nix develop                          # provides sops, opentofu, nixos-anywhere, gcloud
bash scripts/deploy-gcp.sh           # plan + apply (interactive)
bash scripts/deploy-gcp.sh -auto-approve
bash scripts/deploy-gcp.sh -destroy  # tear down bootstrap infra
```

The script:

1. Decrypts the pre-baked SSH host key.
2. Runs `tofu apply` to create the GCE VM (with the host key in metadata + the operator's bootstrap pubkey).
3. Waits for SSH to come up.
4. Runs `nixos-anywhere --flake '.#homeserver-gcp'` to install NixOS over the bootstrap image.

Before the first run, copy `infra/terraform.tfvars.example` to `infra/terraform.tfvars` and fill in the GCP project ID.

## First Deploy Checklist

When provisioning from scratch:

1. **Fill in real secrets** — `sops hosts/homeserver-gcp/secrets/secrets.yaml`, set:
   - `tailscale_auth_key` — Tailscale admin → Settings → Keys → reusable + ephemeral
   - `user_password` — bcrypt hash: `mkpasswd -m bcrypt`
   - `grafana_admin_password`, `grafana_secret_key`, `observability_ingest_htpasswd`
   - `restic_password`, `b2_credentials` (env-file format: `B2_ACCOUNT_ID=…` / `B2_ACCOUNT_KEY=…`)

2. **Provision the VM + install NixOS** — `bash scripts/deploy-gcp.sh` (see above).

3. **Wait ~60s for first boot** — sops decrypts secrets, Tailscale joins the tailnet.

4. **Confirm reachability** — `tailscale status | grep homeserver-gcp`.

5. **Remove bootstrap metadata** — run the command printed by `tofu output ssh_host_key_removal_cmd` to scrub the host key, bootstrap pubkey, and startup script from instance metadata.

6. **Create Vaultwarden account** — temporarily set `SIGNUPS_ALLOWED = true`, deploy, sign up, set back to `false`, redeploy.

7. **Set up AdGuard Home** — open `http://<tailscale-ip>:3001` in a browser and complete the setup wizard (create admin user, confirm DNS on port 53). Then in Tailscale admin → DNS → Nameservers, add the homeserver-gcp Tailscale IP as a global nameserver.

## Ongoing Updates

```bash
deploy '.#homeserver-gcp'
```

## Gotchas

- **sops fails on first boot if host key wasn't injected** — Tailscale won't join, SSH won't
  work over Tailscale. Recover via GCE serial console or `gcloud compute ssh` (project SSH keys
  bypass tailnet-only firewall during recovery).
- **TLS cert is not ACME** — `tailscale-cert.service` fetches it via `tailscale cert`; nginx
  depends on that service via `requires=` so it doesn't start without a cert. A daily
  `tailscale-cert.timer` renews the material and reloads nginx if it is already running.
- **Access is tailnet-only** — `tailscale0` is the only interface that permits inbound SSH/HTTPS.
- **Grafana SSO is Tailscale-aware at nginx** — `/grafana/` now runs through a localhost
  auth helper that resolves the caller with `tailscale whois` and injects Grafana
  auth-proxy headers. Human users land in Grafana as `Viewer` by default unless
  `grafanaTailscaleRoleMap` in `default.nix` promotes specific logins.
- **Grafana break-glass remains local-only** — if the auth helper or role mapping locks
  you out, forward localhost over SSH and use the local Grafana admin account:
  `ssh -L 3000:127.0.0.1:3000 user@homeserver-gcp.tail90fc7a.ts.net`, then open
  `http://127.0.0.1:3000/`.
- **Disk is stateful** — no impermanence or `/persist`. Data survives reboots naturally on root.
- **GCE snapshots are not backups** — use them for fast rollback inside GCP; use restic/B2
  for independent off-site application recovery.
- **Off-site backup via B2** — `services.restic.backups.b2` uses the shared
  `backup.class = "critical"` policy from `modules/nixos/profiles/backup.nix`.
- **AdGuard DNS failure** — if `adguardhome.service` crashes, tailnet clients using it as DNS lose resolution. Recovery: in Tailscale admin → DNS, temporarily remove the nameserver override to fall back to default resolver. The existing systemd failed-unit alert fires within 2 minutes.
- **AdGuard web UI** — HTTP only (port 3001 on tailscale0). No TLS needed; WireGuard encrypts tailnet traffic.
