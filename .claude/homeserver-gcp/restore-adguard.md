# AdGuard Home Restore Runbook

Restores AdGuard Home state from the restic/B2 backup.

AdGuard runs as a DynamicUser service. Its state lives at `/var/lib/private/AdGuardHome`
(systemd-managed) and is symlinked from `/var/lib/AdGuardHome`. Restic backs up a
root-owned staging copy at `/var/lib/restic-staging/adguardhome` created by
`backupPrepareCommand` before each run.

## Steps

```bash
# 1. Stop the service
systemctl stop adguardhome

# 2. Source B2 credentials and pick a snapshot
set -a; source /run/secrets/b2_credentials; set +a
restic --repository-file=/run/secrets/restic_repository \
       --password-file=/run/secrets/restic_password \
       snapshots --path /var/lib/restic-staging/adguardhome

# 3. Restore to a temp path
workdir=$(mktemp -d /var/lib/restic-restore.XXXXXX)
restic --repository-file=/run/secrets/restic_repository \
       --password-file=/run/secrets/restic_password \
       restore latest --target "$workdir" \
       --include /var/lib/restic-staging/adguardhome

# 4. Rsync into the live path — trailing slash is required; do NOT replace the symlink
rsync -a --delete "$workdir/var/lib/restic-staging/adguardhome/" /var/lib/AdGuardHome/
rm -rf "$workdir"

# 5. Start the service — DynamicUser chowns the tree automatically, no manual chown needed
systemctl start adguardhome
```

## Notes

- **`AdGuardHome.yaml` in the restore is harmless** — the next NixOS activation
  overwrites it from the Nix config (`mutableSettings = false`).
- **DNS failure fallback** — while the service is down, tailnet clients lose DNS.
  In Tailscale admin → DNS, temporarily remove the nameserver override to fall
  back to the default resolver before starting the restore.
- To restore a specific snapshot instead of `latest`, replace `latest` with the
  snapshot ID from `restic snapshots`.
