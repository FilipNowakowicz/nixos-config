# Backup inventory

Repository-only inventory as of 2026-11-08. This describes configured intent,
not observed backup health. No cloud or backup account, decrypted secret, live
filesystem, or deployed system was inspected. Nothing was deleted or changed in
backup configuration. The active fleet is defined in [the host registry](../lib/hosts.nix).

## Shared policy and recovery dependencies

[The backup profile](../modules/nixos/profiles/backup.nix) schedules restic daily,
with persistent catch-up and up to 30 minutes of randomized delay. It initializes
repositories and applies [the retention policy](../lib/backup-policy.nix):

| Class | Retained recovery points |
| --- | --- |
| `standard` (`main`) | 7 daily, 4 weekly, 3 monthly |
| `critical` (`homeserver-gcp`) | 14 daily, 8 weekly, 6 monthly, 2 yearly |

Retention groups snapshots by host, including snapshots with older path lists.
These counts are selection rules, not proof those recovery points exist.

Both restic jobs depend on host-scoped sops secrets named `restic_repository`
(the destination URI), `restic_password`, and `b2_credentials` (B2 account ID and
application key). The code wires a B2 environment and documents B2 as the backend;
the exact bucket, prefix, credential permissions, and whether the two hosts use
separate repositories are hidden in encrypted configuration and unverified.
Decryption needs the host's SSH-derived age identity or the personal age key;
recovery after total host loss also needs access to the encrypted Git repository
and an independent decryption identity. The documented fleet-wide route is the
personal key; a separately retained host SSH key can recover that host’s secrets. See [key escrow](key-escrow.md).

## `main`

Source: [workstation backup configuration](../hosts/main/backups.nix).

### Restic job `local` (configured for B2)

Despite its name, `services.restic.backups.local` is not evidence of a second,
on-disk restic repository. It reads the destination from `restic_repository` and
uses `b2_credentials`. No separate local restic repository is declared here.
It runs daily with the `standard` retention above.

Its complete configured path list is:

- Under `/home/user`: `.ssh`, `.gnupg`, `nix`, `.mozilla/firefox`,
  `.config/mozilla/firefox`, `.config/spotify`, `.config/discord`, `.config/gh`,
  `.config/gcloud`, `.local/share/Anki2`, `.config/chromium`,
  `.local/share/kwalletd`, `.codex`, `.claude`, `.claude.json`,
  `.local/share/quiet-shell/notes.md`, and `.config/sops`.
- Under `/etc`: `machine-id`, `ssh/ssh_host_ed25519_key`,
  `ssh/ssh_host_ed25519_key.pub`, `NetworkManager/system-connections`, and
  `mullvad-vpn`.
- Under `/var/lib`: `tailscale`, `bluetooth`, `fprint`, `tudor`, `sbctl`,
  `usbguard`, and `libvirt` (including VM definitions and disk images).

Exclusions: gcloud `access_tokens.db`, `credentials.db`, `logs`, and
`legacy_credentials`; libvirt `images/*.iso`, `images/*.snap`, and
`qemu/{save,dump,ram,snapshot}`. These are deliberate exclusions, not additional
backup destinations.

**Verification:** `restic-check-local` runs weekly, persistent, with up to two
hours of random delay, and checks repository structure plus a 1 GiB data sample.
The backup and check emit success timestamps. No workstation file-restore canary
or service-start restore drill is configured in this host module. Integrity
checking is weaker evidence than a successful restore. The [manual drill](restore-drill.md)
covers homeserver services, not a complete workstation recovery.

**Secrets:** the three restic/B2 secrets above; host key/personal age key for
sops recovery. The backup includes `.config/sops`, but that alone cannot solve
loss of the personal key: the restic password is itself encrypted by sops.

### Local Btrfs snapshots and root rollback

`btrbk-local` runs daily, snapshot-only, for `@home` and `@persist`, writing to
`/.btrfs-root/.snapshots` on the same `main-root` filesystem. Settings are
`snapshot_preserve_min = "2d"` and `snapshot_preserve = "14d"`. This is a local
rollback layer with no independent disk copy and no repository password.
Access to an encrypted source disk requires its unlock credentials.

[Impermanence](../hosts/main/impermanence.nix) also retains previous ephemeral
roots under `/old_roots/<timestamp>`, pruning entries older than 30 days on boot. The blank root used for boot
rollback is a reset baseline, not a copy of personal data. Neither mechanism
protects against source-disk loss. No automated restore test of these snapshots
is declared in these modules. Anonymous specialisations disable the
workstation backup/check and btrbk services; those sessions do not provide the
normal host's backup schedule (see [anonymous configuration](../hosts/main/anonymous.nix)).

## `homeserver-gcp`

Source: [homeserver backups](../hosts/homeserver-gcp/backups.nix).

### Restic job `b2`

Daily B2 backup with `critical` retention. Paths are `/var/lib/grafana`,
`/var/lib/restic-backup-canary`, and `/var/lib/restic-staging/adguardhome`.
Before backup, the job writes a known canary, copies `/var/lib/AdGuardHome/` into
the staging directory with rsync, and creates a consistent Grafana SQLite copy
at `/var/lib/grafana/grafana.db.backup`. It excludes the live `grafana.db`, its
WAL/SHM files, and staged AdGuard `data/querylog.json`. AdGuard staging avoids
backing up only its public DynamicUser symlink; no service pause is configured
for that rsync copy.

**Verification:** weekly `restic-check-b2` checks a 1 GiB sample, persistent with
up to two hours of random delay. A daily restore canary runs at 04:30, persistent
with up to 30 minutes of random delay: it reads the latest marker from B2 without
cache, compares content, restores the Grafana SQLite copy, and requires
`PRAGMA integrity_check` to return `ok`.

[The automated restore drill](../hosts/homeserver-gcp/restore-drill.nix) runs
January/April/July/October 1 at 05:30, persistent with up to one hour of random delay. It
restores Grafana and staged AdGuard into scratch space and starts their binaries
in isolated network namespaces, checking Grafana health, AdGuard web access and
DNS. [Manual quarterly recovery instructions and past results](restore-drill.md)
are separate evidence; recorded historical success does not establish current
health. [Backup validation](backup-validation.md) explains metrics and stale
alerts. None of these checks is a whole-VM restore.

**Secrets:** `restic_repository`, `restic_password`, `b2_credentials` and sops
recovery identity as above. Restoring the running services also needs their
current configuration/secrets, including Grafana and AdGuard credentials.

### GCE boot-disk snapshots

[Terraform](../infra/main.tf) attaches `homeserver-gcp-boot-daily-snapshots` to
the homeserver boot disk. [Defaults](../infra/variables.tf) schedule daily at
03:00 UTC, with maximum retention 7 days and storage in the VM region unless
overridden. `KEEP_AUTO_SNAPSHOTS` preserves scheduled snapshots on source-disk
deletion; do not assume a deleted disk's snapshots expire on the normal window.
This is provider-local disk recovery, including on-disk state outside the B2
path list; it is not an independent off-provider copy or a guarantee of
application-consistent databases. Actual variable overrides are unverified.

**Verification and access:** no automated GCE snapshot restore exercise is
declared in this repo. Recovery requires an authorized GCP identity/IAM access
to snapshots and target compute/storage resources, plus guest recovery secrets
as needed. Snapshot creation is provider-managed, independent of restic/B2 keys.

## `gcp-builder`, `gcp-agent`, and other outputs

Neither cloud host has a registry backup class, restic job, or scheduled GCE
snapshot attachment declared. There is no backup schedule, retention, or restore
check for either. The registry explicitly treats them as disposable:

- `gcp-builder`: recover configuration and build store by reprovisioning;
  no host sops identity is declared (`sops = false`). Bootstrap/operator SSH and
  GCP access are recovery dependencies, not a backup.
- `gcp-agent`: recover repo clone/store by reprovisioning; encrypted host-scoped
  login credentials and GitHub access are managed through sops. Personal age
  key/host identity and provisioning access are recovery dependencies. Work
  existing only in unpushed branches, worktrees, or session files is not covered
  by a declared backup.

The installer and CI configurations are generated/test outputs, not additional
persistent backed-up hosts. The WSL Home Manager output has no backup job of its
own declared here; its surrounding Windows/WSL backup policy is outside this repo.

## Key escrow (cross-host recovery)

[The escrow runbook](key-escrow.md) calls for the personal age key
`~/.config/sops/age/keys.txt` in an independent Bitwarden secure note and an
offline paper copy. These are prescribed copies, not verified existing copies.
There is no automated schedule or retention; replace and test the copies after
key rotation or recovery. The test decrypts a repo secret using the retrieved
copy rather than the live key. Access depends on independent password-manager
recovery credentials or physical access to the paper. No password-manager or
physical escrow was accessed for this inventory.

## Findings for human decision

These are review questions, not instructions to delete data or change policy.

### Overlap and possible redundancy

- `main` Btrfs snapshots and B2 overlap for selected home/persisted state, but
  protect against different failures. Same-disk snapshots do not replace B2.
- Homeserver GCE snapshots overlap with B2 Grafana/AdGuard data. Decide whether
  provider rollback speed warrants the extra storage; B2 offers a separate
  provider and application-oriented restore checks.
- The repo clone and encrypted keys may appear in Git, B2, and escrow-related
  recovery material. Independent personal-key escrow breaks the fleet-wide
  key/password recovery cycle; a separately retained host identity can recover
  that host’s secrets. Copies behind the same locked backup are not independent.
- No second on-disk restic job on `main` is declared. Whether old repositories,
  snapshots, or buckets are redundant cannot be established from this tree.

### Important state without an independent declared backup

- `main` only sends the selected paths above to B2. Other personal documents,
  source work outside `~/nix`, and application state elsewhere in `/home/user`
  have same-disk `@home` snapshot coverage, but no declared off-host coverage.
  Decide which data matters; this inventory does not assert such files exist.
- Homeserver Mimir, Loki, and Tempo state uses local directories under
  `/var/lib` ([backend configuration](../modules/nixos/profiles/observability/backends.nix))
  outside the restic list. They rely on GCE disk snapshots for backup, with no
  independent B2 copy or corresponding restore exercise. Decide whether telemetry
  history and alerting state are disposable.
- Homeserver Tailscale identity and other unlisted runtime state have
  disk-snapshot coverage only. The pre-baked SSH host identity is also stored
  encrypted in Git (see [provisioning](../.claude/homeserver-gcp/provisioning.md));
  recovering it requires a working sops decryption identity. Other declarative
  credentials/configuration can likewise be reconstructed from Git plus keys.
- Disposable agent work is lost on disk loss unless pushed/copied elsewhere.
  Decide whether that matches actual usage. Workstation live browser/Anki/VM
  data also lacks the explicit quiescing/SQLite staging used for Grafana; a
  successful file backup does not prove application-consistent recovery.

### Removed or potentially stale paths

- `/var/lib/vaultwarden` belongs to the removed service. It is absent from the
  current restic path lists and current service configuration. Historical drill
  records intentionally mention it. The repo cannot establish whether residual
  files, B2 snapshots containing it, or GCE disk images still exist; retention
  or deletion of those is a separate human decision.
- The older AdGuard restore instructions in `restore-drill.md` still use
  `/var/lib/private/AdGuardHome`, while the current backup selects
  `/var/lib/restic-staging/adguardhome`. Older snapshots may contain the former;
  inspect the selected snapshot's paths before a future restore. This inventory
  does not rewrite historical records or execute recovery commands.
- The two Firefox locations and other selected workstation paths may be
  alternatives or absent on a given install. No live path-existence audit was
  performed; source declarations alone cannot certify them missing.

## What remains unknown without live verification

Actual applied host generations and Terraform overrides; whether timers have
run successfully; newest usable snapshot age and full retained history; exact
restic destinations, sizes, quotas, lifecycle policies and credential scope;
GCE snapshot existence, IAM, costs and restore usability; obsolete remote data;
and existence/freshness of escrow copies. This document establishes none of
those facts. A human-authorized account and restore review is needed to settle
them. No backup cleanup or configuration change is proposed by this inventory.
