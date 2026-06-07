# Restore Drill

Quarterly procedure for verifying that Vaultwarden, Grafana, and AdGuard Home
data can be recovered from the B2 restic repository.

**Last drill:** 2026-06-07 - automated `restore-drill-b2.service` run (first
execution after deploy): Vaultwarden, Grafana, and AdGuard Home all restored
from B2 into the scratch root and came up successfully against the recovered
state (`restore-drill: full-service restore drill PASSED`,
`restore_drill_last_success_timestamp_seconds = 1780824447`). The manual
quarterly exercise below has not yet been run by a human; the automated drill
exercises the same recovery path on its quarterly schedule in the meantime.

This field records the last manual quarterly restore exercise. The homeserver
backup milestone also added the restore runbook, weekly `restic-check-b2`
verification, and the Grafana **Backup Health** dashboard.

This drill is layer 6 of the broader backup validation pattern — the human
exercise that complements the automated restore canary, freshness metrics, and
stale alerts. See [`backup-validation.md`](backup-validation.md) for the full
verification contract.

---

## Automated full-service drill

The manual procedure below is the human exercise. Between human drills, an
**unattended full-service drill** proves the same path on a schedule, defined in
[`hosts/homeserver-gcp/restore-drill.nix`](../hosts/homeserver-gcp/restore-drill.nix).

What it does: restores Vaultwarden, Grafana, and AdGuard Home from the B2 restic
repository into a throwaway scratch root (`/var/lib/restore-drill/scratch`,
wiped on every run) and then **starts each service binary against the restored
state in its own `PrivateNetwork=true` namespace**, asserting it comes up:

- **Vaultwarden** answers `GET /alive` after opening the restored `db.sqlite3`.
- **Grafana** reports `database: ok` on `GET /api/health` after opening the
  restored `grafana.db`.
- **AdGuard Home** passes `--check-config` on the restored config, then serves
  the public `GET /login.html` route (proving the web server bound — the
  `/control/*` API is auth-gated and would 302 unauthenticated) and answers a
  loopback `dig` query (proving the DNS engine itself is up and processing).

Only after all three come up does it stamp
`restore_drill_last_success_timestamp_seconds` to the node-exporter textfile
collector. `set -eu` means any failed bring-up skips the stamp and leaves the
metric stale.

**It never touches live data.** Restores go to an explicit scratch `--target`;
the `PrivateNetwork` namespace makes the scratch instances unable to collide
with the live DNS:53 / Grafana / Vaultwarden listeners or reach the network; and
the drill never enables, reloads, or stops any live unit. The daily restore
canary in [`backups.nix`](../hosts/homeserver-gcp/backups.nix) is untouched and
keeps running on its own timer — this complements it.

### Triggering

- **Scheduled:** `restore-drill-b2.timer` fires quarterly (1st of Jan/Apr/Jul/Oct,
  ~05:30 + jitter, `Persistent = true`).
- **On demand:** run it immediately on the host with

  ```bash
  sudo systemctl start restore-drill-b2.service
  journalctl -u restore-drill-b2.service -f
  ```

  A `restore-drill: full-service restore drill PASSED` line and a fresh
  `restore_drill_last_success_timestamp_seconds` mean success.

### Where results are recorded

- **Metric:** `restore_drill_last_success_timestamp_seconds`, surfaced on the
  Grafana **Overview** dashboard as the **Restore Drill Age (d)** tile.
- **Alert:** `RestoreDrillStale` (warning) fires if no successful drill has been
  recorded in ~100 days (one quarter + buffer), via the shared
  [`lib/observability-alerts.nix`](../lib/observability-alerts.nix).
- **This file:** still records the last _manual_ drill date below; update it
  after a human exercise even though the automated drill keeps the metric green.

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
