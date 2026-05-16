# Operations

This document is the runbook for day-to-day work in this flake. Keep the
README high-level; put command-heavy procedures here.

## Canonical Sources

- `README.md` - project overview, host inventory, feature map.
- `CLAUDE.md` - agent/operator preferences and validation shortcuts.
- `docs/architecture.md` - structural rules and module boundaries.
- `docs/security.md` - secrets, network exposure, and hardening model.
- `docs/restore-drill.md` - quarterly manual restore procedure for the B2 restic repository.

## Deployment Matrix

| Target           | Status | Command                                  | Notes                                        |
| :--------------- | :----- | :--------------------------------------- | :------------------------------------------- |
| `main`           | Active | `nh os switch --hostname main .`         | Primary workstation.                         |
| `homeserver-gcp` | Active | `deploy '.#homeserver-gcp'`              | GCP homeserver; see `scripts/deploy-gcp.sh`. |
| `user@wsl`       | Active | `home-manager switch --flake .#user@wsl` | Portable Home Manager profile for WSL.       |

## main Workstation Operations

`main` is an impermanent workstation. Rebuilds are normal NixOS switches, but
runtime state must either live on `/home`, `/nix`, `/persist`, or be explicitly
listed in `hosts/main/impermanence.nix`.

Switch:

```bash
nh os switch --hostname main .
```

After storage, boot, backup, or impermanence changes, verify the live system:

```bash
journalctl -b -u rollback-root.service --no-pager
findmnt -R / -o TARGET,SOURCE,FSTYPE,OPTIONS
systemctl list-timers --all --no-pager | rg 'restic|btrfs|fstrim|nix'
systemctl --failed --no-pager
```

Force the first backup/check after changing backup coverage:

```bash
sudo systemctl start restic-backups-local.service
sudo systemctl start restic-check-local.service
journalctl -u restic-backups-local.service -n 120 --no-pager
journalctl -u restic-check-local.service -n 120 --no-pager
```

The host declares scoped passwordless sudo for a small set of agent-assisted
maintenance commands. Keep using normal passworded sudo for anything outside
that allowlist.

Clean stale boot artifacts:

```bash
sudo bootctl cleanup
sudo efibootmgr -b 0003 -B
```

Only delete EFI entries after confirming `BootCurrent` and the entry title with
`bootctl status` or `efibootmgr`.

## Homeserver GCE Snapshots

`infra/main.tf` attaches a daily GCE snapshot schedule to the
`homeserver-gcp` boot disk. These snapshots are provider-local rollback points
stored in Google Cloud snapshot storage, in `snapshot_storage_locations` when
set or in `var.region` by default. The default retention is 7 daily snapshots.

Use GCE snapshots for fast VM-shaped rollback after bad deploys, disk mistakes,
or package/config migrations. Use restic/B2 for durable application recovery,
off-site recovery, and point restores of `/var/lib/vaultwarden` or
`/var/lib/grafana`.

Inspect available scheduled snapshots:

```bash
gcloud compute snapshots list \
  --filter='labels.host=homeserver-gcp AND labels.purpose=fast-rollback' \
  --sort-by='~creationTimestamp'
```

Create a temporary disk from a snapshot for inspection or file extraction:

```bash
SNAPSHOT=<snapshot-name>
gcloud compute disks create homeserver-gcp-restore-inspect \
  --zone=europe-west2-a \
  --source-snapshot="$SNAPSHOT" \
  --type=pd-ssd
```

Attach that disk to a temporary recovery VM or to `homeserver-gcp` while it is
stopped, mount it read-only, and copy out the needed files. Delete the
inspection disk after recovery.

For full rollback, prefer creating a replacement VM or replacement boot disk
from the snapshot, then redeploying the NixOS configuration once the system is
reachable. This avoids treating provider-local snapshots as the authoritative
long-term backup and keeps Terraform/OpenTofu state drift visible.

## Homeserver Smoke Tests

`bash scripts/validate.sh smoke-homeserver-gcp` builds the booted NixOS test for
the live homeserver routing surface. The test checks:

- `/` reaches Vaultwarden through Nginx.
- `/grafana/` works as a sub-path deployment.
- `/obs/loki/`, `/obs/mimir/`, and `/obs/otlp/` enforce the expected auth boundary.

Use this before deploy work that touches `hosts/homeserver-gcp/` or the
observability ingress path.

## Tailscale ACL Drift

The generated ACL artifact is also checked against the live tailnet policy by
`.github/workflows/tailscale-acl-drift.yml`, which runs
`bash scripts/check-tailscale-acl-drift.sh`.

Run it locally when changing `lib/acl.nix` or registry-owned Tailscale metadata:

```bash
bash scripts/check-tailscale-acl-drift.sh
```

## Validation

Use the narrowest check that covers the files changed.

```bash
bash scripts/validate.sh flake-eval
bash scripts/validate.sh light
bash scripts/validate.sh host main-ci
bash scripts/validate.sh host homeserver-gcp
bash scripts/validate.sh hosts
bash scripts/validate.sh profile-tests
bash scripts/validate.sh heavy
bash scripts/validate.sh cve-reports
```

Rules of thumb:

- Shared flake, library, or global module changes: run `light` and affected host builds; use `hosts` when impact is broad.
- Desktop profile/Home Manager changes: build `main-ci`.
- Server profile/GCP changes: build `homeserver-gcp`.
- Docs changes: run `bash scripts/validate.sh docs`; CI runs this even for docs-only PRs.
- NixOS test changes: run the relevant smoke/profile test if KVM is available.

## Formatting And Hooks

```bash
nix fmt
nix fmt -- --fail-on-change
pre-commit run --all-files
statix check .
deadnix .
```

`nix develop` installs a `commit-msg` hook in the shared git hooks directory
that removes `Co-authored-by:` trailers.
