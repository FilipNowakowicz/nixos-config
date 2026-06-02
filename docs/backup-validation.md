# Backup Validation Pattern

This repository treats "we have backups" and "we have _proven restores_" as two
different claims. Taking a backup proves only that a job ran; it says nothing
about whether the bytes can be read back, decrypted, and restored to a working
service. This page documents the layered pattern that closes that gap and the
contract each layer is expected to satisfy.

For backup **policy and coverage** — retention classes, which paths each host
backs up, and the persistence model behind them — see
[`docs/security.md`](security.md#backups). For the **manual quarterly exercise**
see [`docs/restore-drill.md`](restore-drill.md). This page is the
**verification contract** that ties those together.

---

## The pattern in one sentence

Drive retention from the host registry, emit a freshness metric on every
automated step, prove restorability continuously with a restore canary, alert on
the **staleness** of each metric rather than on individual failures, and back the
whole thing with config invariants and a periodic human drill.

## Layers

The pattern is composable: a host opts into as many layers as its risk class
warrants. `main` runs layers 1–4 and 6; `homeserver-gcp` runs all six.

### 1. Retention by class (registry-driven)

`modules/nixos/profiles/backup.nix` reads `hostMeta.backup.{class,name}` from the
host registry (`lib/hosts.nix`) and sets the restic `pruneOpts` and a daily
timer. There are two classes:

| Class      | Retention                               |
| :--------- | :-------------------------------------- |
| `critical` | 14 daily, 8 weekly, 6 monthly, 2 yearly |
| `standard` | 7 daily, 4 weekly, 3 monthly            |

`backup.name` selects which `services.restic.backups.<name>` job receives the
policy (default `local`). The module only sets retention and scheduling; the host
owns the paths, secrets, and backend. A host with no `backup.class` gets no
backup module at all — the registry is the single switch.

### 2. Backup freshness metric

Each backup job stamps `restic_last_backup_timestamp_seconds` from its
`ExecStartPost` via the `mkPromScript` helper
(`config.lib.profiles.observability`). The metric is a Prometheus textfile
written to the node-exporter textfile collector directory. Because
`ExecStartPost` only runs after every `ExecStart` command succeeds, reaching the
script already means the backup completed cleanly — the timestamp is the proof
the job finished, not merely that it started.

### 3. Periodic integrity check

A weekly `restic-check-{local,b2}` service runs `restic check
--read-data-subset=1G` and stamps `restic_last_check_timestamp_seconds`. This
verifies repository structure and re-reads a sampled slice of pack data, catching
silent backend corruption that a successful _write_ would never reveal.

### 4. Restore canary (the actual restore proof)

This is the layer that distinguishes a _proven_ restore from a hopeful one. It is
currently implemented on `homeserver-gcp` (`hosts/homeserver-gcp/backups.nix`):

1. **Seed.** The backup job's `backupPrepareCommand` writes a known string to a
   canary file (`/var/lib/restic-backup-canary/homeserver-gcp.txt`) that is
   included in the backup paths, so every snapshot carries a fresh, predictable
   marker.
2. **Restore.** A separate daily `restic-restore-canary-b2.service` restores that
   file from the `latest` snapshot into a throwaway `tmpdir` with `restic dump
--path … --no-cache`, deliberately bypassing the local cache so it exercises a
   real read from the off-site B2 backend.
3. **Verify.** `grep -qx` asserts the restored content matches the known marker
   exactly.
4. **Stamp.** On success it writes `restic_last_restore_test_timestamp_seconds`.

A green metric here means the full path — backend read, decrypt, restore,
content match — worked end to end within the last cycle, unattended.

### 5. Stale alerts (alert on staleness, not failures)

`lib/observability-alerts.nix` turns the three timestamps into Mimir ruler alerts
that fire on **age**, not on a failed run:

| Alert                      | Fires when                                  |
| :------------------------- | :------------------------------------------ |
| `ResticBackupStale`        | last backup older than 26h (daily + buffer) |
| `ResticCheckStale`         | last integrity check older than 8d          |
| `ResticRestoreCanaryStale` | no successful restore canary for >50h       |

Alerting on staleness rather than on individual job failures means a job that
silently stops scheduling — the failure mode a per-run alert misses entirely — is
still caught, and a single transient failure that the next run recovers from does
not page. The alert rules are linted in CI against the exact data the
observability module deploys (`observability-alerts-lint` in `flake/checks.nix`),
so a typo in a metric name fails the light lane instead of shipping a
never-firing rule.

### 6. Manual restore drill

Automation proves the canary file round-trips; it does not prove a human can
recover a real service under pressure. [`docs/restore-drill.md`](restore-drill.md)
is the quarterly procedure that restores Vaultwarden, Grafana, and AdGuard Home
from B2 into a throwaway target and records the date and outcome. Run it on a
schedule; the canary does not replace it.

---

## What CI enforces

Backup invariants are host-config assertions and live in `flake/checks.nix`
(wired through `mainBackupInvariants` / `homeserverBackupInvariants` into
`invariantChecks`), distinct from the `lib/*` eval tests in `flake/dev.nix`:

- **`mainBackupPathsArePersisted`** — every `services.restic.backups.local.path`
  must be persisted (or on a persistent filesystem). A backed-up path that is not
  persisted would be wiped on the next impermanence rollback and then back up an
  empty directory — silent data loss this assertion makes impossible.
- **`mainBtrbkPolicyMatchesLocalSnapshotIntent`** — pins the local btrbk snapshot
  scope and retention so same-disk rollback coverage cannot drift.
- **`homeserverGcpB2BackupUsesCriticalPolicy`** — asserts the B2 job carries the
  canary path, sources its repository/password/credential files from
  `/run/secrets/*`, initializes, uses the `critical` `pruneOpts`, and runs daily.

These make the _configuration_ of the pattern self-checking; the metrics and
drill verify its _runtime_ behaviour.

---

## Coupling and reuse boundary

The layers are deliberately not a generic multi-backend framework, and should not
become one. Layer 1 (retention by class) is the cleanest reusable piece but reads
the `hostMeta` special arg, so it is meaningful only inside this flake's module
graph. The restore canary (layer 4) is coupled to **restic** (`dump --path`),
**Backblaze B2** (the `EnvironmentFile` credentials), and the **Prometheus
textfile collector** (`mkPromScript`, which requires the observability profile).

If the inline canary is lifted into a reusable module later, its natural option
boundary is: `repositoryFile` / `passwordFile` / `environmentFile` (host sops
paths), `canaryDir` / `canaryContent` (with defaults), and `onCalendar`. The host
keeps the secret wiring, the backup job's path entry, and the
`backupPrepareCommand` write, because the canary must be seeded _before_ and
_included in_ the backup it later verifies. It has a single consumer today, so it
stays inline until a second host needs it.

---

## Adding the pattern to a host

1. Set `backup.class` (and optionally `backup.name`) in the host's `lib/hosts.nix`
   entry to opt into retention + scheduling (layer 1).
2. Define the `services.restic.backups.<name>` job — paths, `repositoryFile`,
   `passwordFile`, `environmentFile` — in the host config. Keep secret handles on
   `/run/secrets/*`.
3. Stamp `restic_last_backup_timestamp_seconds` from the job's `ExecStartPost`
   with `mkPromScript` (layer 2), and add a weekly `restic-check-<name>` service
   for layer 3.
4. For a critical host, add a restore canary modelled on
   `hosts/homeserver-gcp/backups.nix` (layer 4): seed a marker via
   `backupPrepareCommand`, restore-and-verify it on a separate timer, and stamp
   `restic_last_restore_test_timestamp_seconds`.
5. The stale alerts (layer 5) are already shared in
   `lib/observability-alerts.nix`; any host shipping the metrics gets them for
   free once it scrapes into the stack.
6. Schedule the host into the quarterly drill (layer 6) if it holds
   irreplaceable service state.
