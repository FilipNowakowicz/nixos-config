# AdGuard Home Restore Runbook

Restores AdGuard Home state from the restic/B2 backup.

AdGuard runs as a DynamicUser service. Its state lives at `/var/lib/private/AdGuardHome`
(systemd-managed) and is symlinked from `/var/lib/AdGuardHome`. Restic backs up a
root-owned staging copy at `/var/lib/restic-staging/adguardhome` created by
`backupPrepareCommand` before each run.

## Steps

On the homeserver in a root Bash shell with Restic and rsync available, restore
and validate the chosen snapshot before taking DNS down. Keep the old state
until the restored service passes its checks.

```bash
set -eu
umask 077
set -a
source /run/secrets/b2_credentials
set +a
export RESTIC_REPOSITORY_FILE=/run/secrets/restic_repository
export RESTIC_PASSWORD_FILE=/run/secrets/restic_password
restic snapshots --host homeserver-gcp
read -rp 'Snapshot ID to recover: ' snap
restic ls "$snap" /var/lib
source_path=/var/lib/restic-staging/adguardhome
# For an older snapshot, use the actual source_path listed above.
workdir=$(mktemp -d /var/lib/restic-restore.XXXXXX)
restic restore "$snap" --target "$workdir" --include "$source_path"
state="$workdir$source_path"
test -s "$state/AdGuardHome.yaml"
test -d "$state/data"
```

For cutover on an initialized host, verify the live destination, stop the service,
and keep a rollback copy in the private work directory. Check available space
for both copies first. If the copy or startup fails, recover the saved tree
with the service stopped before retrying.

```bash
live=/var/lib/AdGuardHome
test "$(readlink -f "$live")" = /var/lib/private/AdGuardHome
test -d "$live/data"
systemctl stop adguardhome
cp -a "$live/." "$workdir/pre-restore"
rsync -a --delete "$state/" "$live/"
systemctl start adguardhome
systemctl is-active --quiet adguardhome
```

Verify a known DNS policy from a client and check the web UI. Remove the private
work directory after accepting the result. The trailing slashes copy contents
and preserve the systemd-managed symlink.

## Notes

- **`AdGuardHome.yaml` in the restore is harmless** — the next NixOS activation
  overwrites it from the Nix config (`mutableSettings = false`).
- **DNS failure fallback** — while the service is down, tailnet clients lose DNS.
  In Tailscale admin → DNS, temporarily remove the nameserver override to fall
  back to the default resolver before starting the restore.
