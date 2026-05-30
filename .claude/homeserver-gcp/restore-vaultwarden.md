# Vaultwarden Restore Runbook

Restores Vaultwarden state from the restic/B2 backup.

Vaultwarden runs as a static `vaultwarden` system user. State lives at
`/var/lib/vaultwarden` (mode 0700). `backupPrepareCommand` snapshots the live
DB via `sqlite3 .backup` to `db.sqlite3.backup` before each restic run; the
live `db.sqlite3` is excluded. The restored tree contains `db.sqlite3.backup`
which must be renamed to `db.sqlite3` before starting the service (step 6).

## Steps

```bash
# 1. Stop Vaultwarden (and nginx to prevent stale upstream connections)
systemctl stop vaultwarden nginx

# 2. Source B2 credentials and list snapshots
set -a; source /run/secrets/b2_credentials; set +a
restic --repository-file=/run/secrets/restic_repository \
       --password-file=/run/secrets/restic_password \
       snapshots --path /var/lib/vaultwarden

# 3. Restore to a staging path
workdir=$(mktemp -d /var/lib/restic-restore.XXXXXX)
restic --repository-file=/run/secrets/restic_repository \
       --password-file=/run/secrets/restic_password \
       restore latest --target "$workdir" \
       --include /var/lib/vaultwarden

# 4. Check DB integrity before swapping in
sqlite3 "$workdir/var/lib/vaultwarden/db.sqlite3" "PRAGMA integrity_check;"
# Expected output: "ok"

# 5. Swap in the restored state, keeping the old data as a fallback
mv /var/lib/vaultwarden /var/lib/vaultwarden.bak.$(date +%Y%m%d-%H%M%S)
mv "$workdir/var/lib/vaultwarden" /var/lib/vaultwarden
rm -rf "$workdir"

# 6. Promote the consistent snapshot to the live DB path
mv /var/lib/vaultwarden/db.sqlite3.backup /var/lib/vaultwarden/db.sqlite3

# 7. Fix ownership and permissions (static user, not DynamicUser — chown is required)
chown -R vaultwarden:vaultwarden /var/lib/vaultwarden
chmod 700 /var/lib/vaultwarden

# 8. Start services
systemctl start vaultwarden nginx
```

## Verify

```bash
systemctl status vaultwarden
# Check the web UI is reachable over the tailnet
curl -si https://$(tailscale ip -4 | head -1)/ | head -5
# Remove the fallback dir once satisfied
rm -rf /var/lib/vaultwarden.bak.*
```

## Notes

- **rclone/B2 egress cost** — a full restore of `/var/lib/vaultwarden` is small
  (typically <100 MB); cost is negligible.
- **Dry-run test** — to verify a snapshot is restorable without touching the live
  path, run `restic restore latest --dry-run --include /var/lib/vaultwarden`.
- To restore a specific snapshot instead of `latest`, replace `latest` with the
  snapshot ID from `restic snapshots`.
