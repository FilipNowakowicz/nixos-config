# Restore Drill

Quarterly procedure for verifying that Vaultwarden and Grafana data can be
recovered from the B2 restic repository.

**Last drill:** _(not yet performed)_

---

## Prerequisites

```bash
nix develop   # provides restic, sops
```

Export credentials for the duration of the drill:

```bash
export RESTIC_REPOSITORY="b2:filipnowakowicz-gcp:"
export RESTIC_PASSWORD_FILE="$(sops --decrypt --extract '["restic_password"]' \
  hosts/homeserver-gcp/secrets/secrets.yaml | mktemp --suffix=.pass)"
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

## 3. Restore Grafana

```bash
SNAP=latest
TARGET=$(mktemp -d /tmp/restore-grafana-XXXXXX)

restic restore "$SNAP" --target "$TARGET" --include /var/lib/grafana
ls "$TARGET/var/lib/grafana/"
```

Verify the Grafana database is intact:

```bash
sqlite3 "$TARGET/var/lib/grafana/grafana.db" "SELECT COUNT(*) FROM dashboard;"
```

Clean up:

```bash
rm -rf "$TARGET"
```

## 4. Record result

Update the **Last drill** date at the top of this file with the date and outcome,
e.g.:

```
**Last drill:** 2026-05-08 — both Vaultwarden and Grafana restored successfully
```

---

## Notes

- The restore target is always a throwaway `/tmp` directory — never restore over
  live data during a drill.
- To perform a real recovery, stop the affected service, restore to `/var/lib/`,
  fix ownership (`chown -R vaultwarden:vaultwarden /var/lib/vaultwarden`), and
  restart.
- Restic repository integrity is verified weekly by `restic-check-b2.timer`;
  check Grafana → **Backup Health** for the current check age.
