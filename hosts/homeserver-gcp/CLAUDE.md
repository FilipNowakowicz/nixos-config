# homeserver-gcp Host

GCP-hosted headless server. Runs Vaultwarden, LGTM stack, Tailscale, and Nginx.
No LUKS or impermanence (GCP handles at-rest encryption; state persists on the GCE disk).

Status: **active** — deployed on GCP and accessible via Tailscale.

## Services

- **Vaultwarden** — `127.0.0.1:8222`, proxied via Nginx over HTTPS
- **LGTM stack** — Grafana (sub-path `/grafana/`, Tailscale identity via nginx auth proxy), Loki, Mimir, Tempo (full observability)
- **Nginx** — reverse proxy, TLS via Tailscale cert
- **SSH** — in-guest firewall exposure limited to `tailscale0`; Terraform also
  adds a high-priority GCP firewall deny for public TCP/22 on the default VPC.
- **Tailscale** — auth key from sops secret `tailscale_auth_key`
- **AdGuard Home** — DNS (TCP/UDP 53) + web UI (HTTPS port 3001 via nginx, internal HTTP on 127.0.0.1:13001), tailscale0 only; state is exposed at `/var/lib/AdGuardHome` and stored by systemd at `/var/lib/private/AdGuardHome`
- **Restic/B2** — off-site backups to Backblaze B2 (`/var/lib/vaultwarden`, `/var/lib/grafana`, staged AdGuard state, and a restore canary)
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

## Provisioning & First Deploy

Runbook: [`.claude/homeserver-gcp/provisioning.md`](../../.claude/homeserver-gcp/provisioning.md)

## Ongoing Updates

```bash
deploy '.#homeserver-gcp'
```

## Gotchas

- **sops fails on first boot if the host key was not copied into the installed root** — Tailscale won't join, SSH won't work over Tailscale. Recover via GCE serial console or `gcloud compute ssh` (project SSH keys bypass tailnet-only firewall during recovery), then install the encrypted repo key at `/etc/ssh/ssh_host_ed25519_key` and redeploy.
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
  AdGuard is backed up from `/var/lib/restic-staging/adguardhome` (root-owned
  staging copy) instead of the raw DynamicUser tree. Restore runbook:
  [`.claude/homeserver-gcp/restore-adguard.md`](../../.claude/homeserver-gcp/restore-adguard.md).
  Vaultwarden restore runbook:
  [`.claude/homeserver-gcp/restore-vaultwarden.md`](../../.claude/homeserver-gcp/restore-vaultwarden.md).
- **Restore canary** — `restic-restore-canary-b2.service` restores the latest
  `/var/lib/restic-backup-canary/homeserver-gcp.txt` from B2 and writes
  `restic_last_restore_test_timestamp_seconds` for alerts.
- **Alert delivery** — Alertmanager sends to the sops-backed
  `alertmanager_webhook_url`; keep it pointed at an off-host notification
  target so host or nginx failures can still reach you.
- **AdGuard DNS failure** — if `adguardhome.service` crashes, tailnet clients
  using it as DNS lose resolution. Recovery: in Tailscale admin → DNS,
  temporarily remove the nameserver override to fall back to default resolver.
  The failed-unit alert fires within 2 minutes, but it only leaves the box when
  a real Alertmanager receiver is configured.
- **AdGuard web UI** — HTTPS on port 3001 (proxied by nginx using the Tailscale cert). AdGuard itself binds to `127.0.0.1:13001`. Login: `admin` / see password in session notes or Nix config hash.
