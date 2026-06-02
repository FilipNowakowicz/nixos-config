# Restore Drill

Quarterly procedure for verifying that Vaultwarden, Grafana, and AdGuard Home
data can be recovered from the B2 restic repository.

**Last drill:** _(not yet performed)_

This field records the last manual quarterly restore exercise. The homeserver
backup milestone also added the restore runbook, weekly `restic-check-b2`
verification, and the Grafana **Backup Health** dashboard.

This drill is layer 6 of the broader backup validation pattern — the human
exercise that complements the automated restore canary, freshness metrics, and
stale alerts. See [`backup-validation.md`](backup-validation.md) for the full
verification contract.

---

## Prerequisites

```bash
nix develop   # provides restic, sops
```

Export credentials for the duration of the drill:

```bash
export RESTIC_REPOSITORY="$(sops --decrypt --extract '["restic_repository"]' \
  hosts/homeserver-gcp/secrets/secrets.yaml)"
export RESTIC_PASSWORD_FILE="$(mktemp --suffix=.pass)"
chmod 600 "$RESTIC_PASSWORD_FILE"
sops --decrypt --extract '["restic_password"]' \
  hosts/homeserver-gcp/secrets/secrets.yaml > "$RESTIC_PASSWORD_FILE"
# B2 credentials
eval "$(sops --decrypt --extract '["b2_credentials"]' \
  hosts/homeserver-gcp/secrets/secrets.yaml)"
export B2_ACCOUNT_ID B2_ACCOUNT_KEY
```

## 1. List snapshots

```bash
restic snapshots
```

Note the snapshot ID to restore (typically the latest).

## 2. Restore Vaultwarden

```bash
SNAP=latest   # replace with specific snapshot ID if needed
TARGET=$(mktemp -d /tmp/restore-vaultwarden-XXXXXX)

restic restore "$SNAP" --target "$TARGET" --include /var/lib/vaultwarden
ls "$TARGET/var/lib/vaultwarden/"
```

Verify the `db.sqlite3` file is present and readable:

```bash
sqlite3 "$TARGET/var/lib/vaultwarden/db.sqlite3" "SELECT COUNT(*) FROM users;"
```

Clean up:

```bash
rm -rf "$TARGET"
```

Real recovery:

```bash
sudo systemctl stop vaultwarden.service
sudo restic restore "$SNAP" --target / --include /var/lib/vaultwarden
sudo chown -R vaultwarden:vaultwarden /var/lib/vaultwarden
sudo systemctl start vaultwarden.service
sudo systemctl status vaultwarden.service --no-pager
```

Verify service data after recovery:

```bash
sudo -u vaultwarden sqlite3 /var/lib/vaultwarden/db.sqlite3 "SELECT COUNT(*) FROM users;"
```

## 3. Restore Grafana

```bash
SNAP=latest
TARGET=$(mktemp -d /tmp/restore-grafana-XXXXXX)

restic restore "$SNAP" --target "$TARGET" --include /var/lib/grafana
ls "$TARGET/var/lib/grafana/"
```

Verify the Grafana database is intact:

```bash
sqlite3 "$TARGET/var/lib/grafana/grafana.db.backup" "SELECT COUNT(*) FROM dashboard;"
```

Clean up:

```bash
rm -rf "$TARGET"
```

Real recovery:

```bash
sudo systemctl stop grafana.service
sudo restic restore "$SNAP" --target / --include /var/lib/grafana
sudo install -o grafana -g grafana -m 0600 /var/lib/grafana/grafana.db.backup /var/lib/grafana/grafana.db
sudo chown -R grafana:grafana /var/lib/grafana
sudo systemctl start grafana.service
sudo systemctl status grafana.service --no-pager
```

Verify service data after recovery:

```bash
sudo -u grafana sqlite3 /var/lib/grafana/grafana.db "SELECT COUNT(*) FROM dashboard;"
```

## 4. Restore AdGuard Home

AdGuard Home runs with `DynamicUser=true` and `StateDirectory=AdGuardHome`.
The public `/var/lib/AdGuardHome` path is a systemd symlink; the Restic backup
uses the real state path at `/var/lib/private/AdGuardHome`.

```bash
SNAP=latest
TARGET=$(mktemp -d /tmp/restore-adguardhome-XXXXXX)

restic restore "$SNAP" --target "$TARGET" --include /var/lib/private/AdGuardHome
ls "$TARGET/var/lib/private/AdGuardHome/"
```

Verify the config and expected data files are present:

```bash
test -s "$TARGET/var/lib/private/AdGuardHome/AdGuardHome.yaml"
test -d "$TARGET/var/lib/private/AdGuardHome/data"
find "$TARGET/var/lib/private/AdGuardHome/data" -type f \
  | grep -E '/(filters/|querylog|stats\.db)' \
  | sort \
  | head
```

Clean up:

```bash
rm -rf "$TARGET"
```

Real recovery:

```bash
sudo systemctl stop adguardhome.service
sudo mkdir -p /var/lib/private
sudo restic restore "$SNAP" --target / --include /var/lib/private/AdGuardHome
sudo systemctl start adguardhome.service
sudo systemctl status adguardhome.service --no-pager
```

Do not chown this directory to a named service account. NixOS runs
`adguardhome.service` with `DynamicUser=true`, and systemd manages the private
state directory ownership when the service starts.

Verify service data after recovery:

```bash
sudo test -s /var/lib/private/AdGuardHome/AdGuardHome.yaml
sudo test -d /var/lib/private/AdGuardHome/data
sudo systemctl is-active --quiet adguardhome.service
```

## 5. Record result

Update the **Last drill** date at the top of this file with the date and outcome,
e.g.:

```
**Last drill:** 2026-05-08 - Vaultwarden, Grafana, and AdGuard Home restored successfully
```

---

## Notes

- The restore target is always a throwaway `/tmp` directory — never restore over
  live data during a drill.
- For real recovery, use the per-service snippets above so the right systemd
  unit, restore path, and ownership model are applied.
- Restic repository integrity is verified weekly by `restic-check-b2.timer`;
  check Grafana → **Backup Health** for the current check age.
