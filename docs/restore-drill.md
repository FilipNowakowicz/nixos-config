# Restore Drill

Quarterly procedure for verifying that Grafana and AdGuard Home
data can be recovered from the B2 restic repository.

The automated `restore-drill-b2.service` exercises the same recovery path on a
quarterly schedule. Its freshness is enforced rather than written down: the
drill exports `restore_drill_last_success_timestamp_seconds`, and the
`RestoreDrillStale` alert in `lib/observability-alerts.nix` fires when
a recorded success is more than 100 days old. An absent success series does
not trigger this age comparison. The homeserver backup milestone
also added the restore runbook, weekly `restic-check-b2` verification, and the
Grafana **Backup Health** dashboard.

This drill is layer 6 of the broader backup validation pattern — the human
exercise that complements the automated restore canary, freshness metrics, and
stale alerts. See [`backup-validation.md`](backup-validation.md) for the full
verification contract.

---

## Automated full-service drill

The manual procedure below is the human exercise. Between human drills, an
**unattended full-service drill** proves the same path on a schedule, defined in
[`hosts/homeserver-gcp/restore-drill.nix`](../hosts/homeserver-gcp/restore-drill.nix).

What it does: restores Grafana and AdGuard Home from the B2 restic
repository into a throwaway scratch root (`/var/lib/restore-drill/scratch`,
wiped on every run) and then **starts each service binary against the restored
state in its own `PrivateNetwork=true` namespace**, asserting it comes up:

- **Grafana** reports `database: ok` on `GET /api/health` after opening the
  restored `grafana.db`.
- **AdGuard Home** passes `--check-config` on the restored config, then serves
  the public `GET /login.html` route (proving the web server bound — the
  `/control/*` API is auth-gated and would 302 unauthenticated) and answers a
  loopback `dig` query (proving the DNS engine itself is up and processing).

Only after both come up does it stamp
`restore_drill_last_success_timestamp_seconds` to the node-exporter textfile
collector. `set -eu` means any failed bring-up skips the stamp and leaves the
metric stale.

**It never touches live data.** Restores go to an explicit scratch `--target`;
the `PrivateNetwork` namespace makes the scratch instances unable to collide
with the live DNS:53 / Grafana listeners or reach the network; and
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
- **Manual result:** record the snapshot ID, date and application checks below
  after a human exercise. The automated service has a separate success metric.

---

## Prerequisites

Use a fresh Bash shell with Restic, SQLite, and sops available. From a
checkout on the recovery machine, `nix shell nixpkgs#restic nixpkgs#sqlite nixpkgs#sops -c bash`
supplies the tools. Run the following in that shell. Use a private filesystem
with enough free space for the restored data.

```bash
set -eu
umask 077
TARGET=$(mktemp -d)
trap 'rm -rf -- "$TARGET"' EXIT
config_file=hosts/homeserver-gcp/secrets/secrets.yaml
sops -d --extract '["restic_repository"]' "$config_file" > "$TARGET/repository"
sops -d --extract '["restic_password"]' "$config_file" > "$TARGET/password"
sops -d --extract '["b2_credentials"]' "$config_file" > "$TARGET/b2.env"
export RESTIC_REPOSITORY_FILE="$TARGET/repository" RESTIC_PASSWORD_FILE="$TARGET/password"
set -a
source "$TARGET/b2.env"
set +a
```

## 1. Select a recovery point

```bash
restic snapshots --host homeserver-gcp
read -rp 'Snapshot ID from the required date: ' SNAP
restic ls "$SNAP" /var/lib
```

Record the ID. A historical snapshot may have a different AdGuard source path.
Use the path actually listed before restoring that snapshot.

## 2. Restore Grafana

```bash
restic restore "$SNAP" --target "$TARGET/data" --include /var/lib/grafana
db="$TARGET/data/var/lib/grafana/grafana.db.backup"
test -s "$db"
test "$(sqlite3 -readonly "$db" 'PRAGMA integrity_check;')" = ok
sqlite3 -readonly "$db" 'SELECT COUNT(*) FROM dashboard;'
```

For real recovery on the service host, stop Grafana after verifying the staged
copy. Preserve the existing data directory, including any WAL and SHM files,
as a rollback copy. Install the restored tree into a clean data directory,
promote `grafana.db.backup` to `grafana.db` with owner and group `grafana` and
mode 0600, then start Grafana. Check `/api/health` and open a known dashboard.

## 3. Restore AdGuard Home

The current backup copies the contents of the service state directory into
`/var/lib/restic-staging/adguardhome`. For snapshots showing this layout:

```bash
ag_path=/var/lib/restic-staging/adguardhome
restic restore "$SNAP" --target "$TARGET/data" --include "$ag_path"
test -s "$TARGET/data$ag_path/AdGuardHome.yaml"
test -d "$TARGET/data$ag_path/data"
```

For an older snapshot listing `/var/lib/private/AdGuardHome`, set `ag_path` to
that path before the restore. Inspect a known filter or client setting. For a
live recovery, follow the [AdGuard cutover procedure](../.claude/homeserver-gcp/restore-adguard.md).
The application reads the systemd-managed state directory. Restoring the
staging directory under the live root leaves that application state untouched.

## 4. Record result

Record the date, selected snapshot ID, results for both services and elapsed
time after a human exercise. Keep private settings out of the record. Exit the
drill shell to remove its credentials and scratch data.

---

## Notes

- The restore target is always a throwaway `/tmp` directory — never restore over
  live data during a drill.
- For real recovery, use the per-service snippets above so the right systemd
  unit, restore path, and ownership model are applied.
- Restic repository integrity is verified weekly by `restic-check-b2.timer`;
  check Grafana → **Backup Health** for the current check age.
