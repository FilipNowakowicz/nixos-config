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

| Target           | Status | Command                                  | Notes                                                                |
| :--------------- | :----- | :--------------------------------------- | :------------------------------------------------------------------- |
| `main`           | Active | `nh os switch --hostname main .`         | Primary workstation.                                                 |
| `homeserver-gcp` | Active | `deploy '.#homeserver-gcp'`              | GCP homeserver; see `scripts/deploy-gcp.sh`.                         |
| `mac`            | Active | `deploy '.#mac'`                         | Companion workstation (2017 MacBook Air); `nh os switch` also works. |
| `user@wsl`       | Active | `home-manager switch --flake .#user@wsl` | Portable Home Manager profile for WSL.                               |

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

Run the narrow drift check after rebuilds when the change could affect
Tailscale identity, tailscale-only ports, or core service state:

```bash
bash scripts/check-host-drift.sh main
```

`main` mounts its primary Btrfs subvolumes with `compress=zstd`; verify that in
the `findmnt` output for `/`, `/home`, `/nix`, and `/persist`. A hidden
maintenance mount at `/.btrfs-root` exposes the filesystem top-level so
`btrbk-local` can snapshot `@home` and `@persist` directly.

`btrbk-local.timer` runs daily, keeps at least 2 days of snapshots, and prunes
anything older than 14 days. These snapshots are for short-term same-disk
recovery only; Restic/B2 remains the off-site disaster recovery path.

Force or inspect the local snapshot job after storage changes:

```bash
sudo systemctl start btrbk-local.service
sudo systemctl status btrbk-local.service --no-pager
sudo systemctl status btrbk-local.timer --no-pager
sudo btrfs subvolume list /.btrfs-root | rg '\.snapshots'
```

Restore from a local snapshot by mounting or copying from the relevant
read-only snapshot under `/.btrfs-root/.snapshots/<subvolume>/`. Prefer local
snapshots for accidental recent edits on the same disk; prefer Restic/B2 for
disk-loss, host-loss, or older point-in-time recovery.

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

Run fixed-argument Nix garbage collection through the allowlisted wrapper:

```bash
sudo nix-gc-14d
```

`main` also hosts companion-workstation services for `mac`: Sunshine runs as a
Home Manager user service tied to `nixos-fake-graphical-session.target`, and
Input Leap is installed in Home Manager. Their network surface is limited to
`tailscale0`; the general LAN firewall remains closed.

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

## Terraform Drift Guard

`bash scripts/validate.sh tf-drift` runs a read-only `tofu plan
-detailed-exitcode` against live GCP state and reports drift (exit `2`). It exists
because the public-SSH edge deny and the snapshot policy carry "apply manually"
notes, so the live project can silently diverge from `main`.

It is a manual/local check, not a CI gate: it needs GCP credentials (ADC) and
`infra/terraform.tfvars`. The plan is `-target`-scoped to the always-on
homeserver resources (instance, both firewalls, snapshot policy + attachment) so
the on-demand `gcp-builder` — which powers itself off and nulls its ephemeral IP
— does not register as perpetual benign drift. `bootstrap_ssh_public_key` is
passed as a placeholder; it is only consumed at first provisioning and held
under `lifecycle.ignore_changes`, so it produces no diff. Run it after any
manual change to `infra/`, or periodically, to confirm live state still matches.

## Homeserver Smoke Tests

`bash scripts/validate.sh smoke-homeserver-gcp` builds the booted NixOS test for
the live homeserver routing surface. The test checks:

- `/` reaches Vaultwarden through Nginx.
- `/grafana/` works as a sub-path deployment.
- exact `/obs/*` ingest endpoints require credentials, and broader
  observability API paths are denied.

Use this before deploy work that touches `hosts/homeserver-gcp/` or the
observability ingress path.

After deploys, run the host drift check from a machine that can reach the
tailnet host:

```bash
bash scripts/check-host-drift.sh homeserver-gcp
```

The first pass checks a narrow set of registry-backed facts:

- Tailscale tag and tailnet FQDN from `lib/hosts.nix`
- Tailscale-only TCP ports derived from `networking.firewall.interfaces.tailscale0.allowedTCPPorts`
- Selected enabled systemd units such as `tailscaled`, `sshd`, and core homeserver services

## Mac Companion Workstation

Deploy from `main`:

```bash
deploy '.#mac'
```

Local fallback on the Mac:

```bash
nh os switch --hostname mac .
```

After Mac changes, check the live host:

```bash
ssh user@mac.example.ts.net
systemctl --failed --no-pager
systemctl --user status syncthing.service --no-pager
systemctl status tailscaled sshd thermald power-profiles-daemon --no-pager
```

Syncthing, Input Leap, and Moonlight still need interactive pairing after a
fresh install. The aliases `input-main`, `input-server`, and `moon-main` are
installed as helpers, but certificate/device approval remains operator state.

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
bash scripts/validate.sh package all
bash scripts/validate.sh profile-tests
bash scripts/validate.sh heavy
bash scripts/validate.sh cve-reports
```

The CVE report workflow also runs weekly and on PRs that touch `flake.lock`.
It scans the current flake-built `main` and `homeserver-gcp` closures and uploads
the report artifact; vulnix advisories fail the workflow. The live homeserver
timer exports only `vulnix_scan_timestamp_seconds`, so dashboards alert on stale
scanner health rather than noisy raw CVE counts from deployed generations.

Rules of thumb:

- Shared flake, library, or global module changes: run `light` and affected host builds; use `hosts` when impact is broad.
- Package/app output changes: run `bash scripts/validate.sh package all`, or
  `bash scripts/validate.sh package <name>` for a narrow check.
- Desktop profile/Home Manager changes: build `main-ci`.
- Server profile/GCP changes: build `homeserver-gcp`.
- Docs changes: run `bash scripts/validate.sh docs`; CI runs this even for docs-only PRs.
- NixOS test changes: run the relevant smoke/profile test if KVM is available.
- `infra/` changes: run `bash scripts/validate.sh tf-drift` (manual/local; needs
  ADC) to confirm live GCP state still matches — see [Terraform Drift Guard](#terraform-drift-guard).

## On-Demand Remote Builder

Build-heavy `scripts/validate.sh` subcommands (`host`, `hosts`, `heavy`,
`profile-test(s)`, `smoke-*`) transparently offload to the on-demand
`gcp-builder` VM. The script starts the VM (idempotent), waits for SSH over
Tailscale, and passes `--builders` for that one invocation; the builder powers
itself off after ~20 minutes idle. No manual start/stop is needed in the common
path.

Offload is a silent no-op — the build runs locally — whenever it cannot help:
`USE_BUILDER=0`, `gcloud` is absent, or the build key is not present (CI, fresh
clones, or a `main` without the wiring deployed). So a cold builder only ever
adds a start-and-wait at the front of a heavy build; it never blocks an ordinary
`rebuild`, which is why the builder is deliberately not registered in
`nix.buildMachines`.

```bash
# Force a purely local build even on a deployed main:
USE_BUILDER=0 bash scripts/validate.sh hosts

# Override the builder location / parallelism:
BUILDER_ZONE=europe-west2-a BUILDER_MAXJOBS=8 bash scripts/validate.sh heavy
```

Prerequisite: `gcloud` on `main` must be authenticated with the builder's
project active (`gcloud config set project <id>`). The full pattern — lifecycle,
trust boundary, and reuse scope — is in
[`remote-builder.md`](remote-builder.md); provisioning and gotchas are in
[`hosts/gcp-builder/CLAUDE.md`](../hosts/gcp-builder/CLAUDE.md).

## Ad Hoc Nix Commands

Interactive `nix` commands resolve `nixpkgs` through this flake's pinned input
on NixOS hosts from this repo.

That means commands such as these should use the same package set as the active
system configuration, rather than an ambient machine-specific registry entry:

```bash
nix run nixpkgs#hello
nix shell nixpkgs#ripgrep
```

Legacy `<nixpkgs>` lookups are also pointed at `flake:nixpkgs` via
`nix.nixPath`, so both flake-style and older shell workflows stay aligned.

On interactive workstation shells, the default command-not-found hook is
replaced with `nix-index`, and `comma` is available for one-off commands:

```bash
, rg pattern .
, fd flake
```

Use `comma` for temporary tools you do not want to add to the permanent package
set.

## Desktop Apps

The control center is now built from the repo-local package at
`packages/control-center/`.

Run the flake app directly during development:

```bash
nix run .#control-center
```

Build the package output without launching it:

```bash
nix build '.#packages.x86_64-linux.control-center'
```

Home Manager installs the same packaged `control-center` binary on `main`, so
desktop behavior should be debugged from the package source rather than from a
deleted `home/files/scripts/control_center.py` script path.

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
