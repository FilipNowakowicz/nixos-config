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

Clean stale boot artifacts:

```bash
sudo bootctl cleanup
sudo efibootmgr -b 0003 -B
```

Only delete EFI entries after confirming `BootCurrent` and the entry title with
`bootctl status` or `efibootmgr`.

### Shutdown diagnostics: services that time out stopping

Spot this class of bug with:

```bash
journalctl -b -1 --no-pager | rg 'State .stop-sigterm. timed out'
```

or by scanning `journalctl -b -1` for a multi-minute gap between "Stopping
X.service..." and the next log line — that gap is the default 90s
`TimeoutStopSec` running out before a SIGKILL.

General pattern: any service that flushes or exports over a network path torn
down by another unit at shutdown (Tailscale, a VPN, NetworkManager) should get
an explicit short `TimeoutStopSec` rather than relying on stop-ordering across
unrelated units — there's no ordering guarantee between, say, `tailscaled`
tearing down and a service's shutdown-time flush needing DNS over it. `main`'s
`prometheus`/`alloy` services hit exactly this (6 timeouts over 2 months
before being fixed with `TimeoutStopSec = "10s"`); see
`modules/nixos/profiles/observability/collectors.nix`.

## Homeserver GCE Snapshots

`infra/main.tf` attaches a daily GCE snapshot schedule to the
`homeserver-gcp` boot disk. These snapshots are provider-local rollback points
stored in Google Cloud snapshot storage, in `snapshot_storage_locations` when
set or in `var.region` by default. The default retention is 7 daily snapshots.

Use GCE snapshots for fast VM-shaped rollback after bad deploys, disk mistakes,
or package/config migrations. Use restic/B2 for durable application recovery,
off-site recovery, and point restores of `/var/lib/grafana`.

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

## Terraform State

State for `infra/` lives in the GCS bucket `nixos-config-tfstate-8c41e7`
(`europe-west2`, under `terraform/state/`), with object versioning, enforced
public access prevention, and uniform bucket-level access. The backend also
provides state locking. State includes sensitive instance attributes, so treat
read access to the bucket as access to those values.

The bucket is deliberately not managed by `infra/`: `deploy-gcp.sh` has a
destroy path, and a bucket held in the state it stores would either block that
path or be caught up in it. It was created once with:

```bash
gcloud storage buckets create gs://nixos-config-tfstate-8c41e7 \
  --project "$GCP_PROJECT" --location europe-west2 \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://nixos-config-tfstate-8c41e7 --versioning
```

`tofu` authenticates to the backend the same way as the provider. If
Application Default Credentials belong to an account without access to the
project, pass the active `gcloud` account's token for that command instead:

```bash
GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)" tofu -chdir=infra plan
```

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

- `/` redirects to the status homepage.
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

## Automated Homeserver Deploy

`Deploy homeserver-gcp` (`.github/workflows/deploy-homeserver.yml`) remains
**disabled in GitHub** pending review, credential provisioning and a successful
manual run. Do not enable it just because the static checks pass.

Once enabled, relevant pushes to `main` and `workflow_dispatch` (confirmation
`homeserver-gcp`, from `main` only) use the same fail-closed path:

1. Require this exact main commit to be a merged PR whose head passed the
   `nix.yml` PR workflow and its `merge-gate` job. Missing API evidence, a
   direct push or a stale main commit stops the run. Recheck before activation.
2. Join the builder tailnet as `tag:ci-builder` using existing builder secrets:
   `BUILDER_CI_GCP_KEY`, `BUILDER_CI_SSH_KEY`, `TS_OAUTH_CLIENT_ID` and
   `TS_OAUTH_SECRET`. Run evaluation, light checks, the homeserver smoke test
   and the host closure build through `scripts/on-builder.sh` and the shared
   `scripts/ci-builder-checks.sh` path. Builder unavailability fails the run;
   there is no GitHub-hosted build fallback for deployment.
3. Build the deploy-rs activation wrapper and client on `gcp-builder`, export
   their complete store closure, and transfer it with a one-day Actions artifact
   tied to the commit. The builder's temporary GC roots protect the bundle
   during transfer; fetched bundles are removed, and leftovers expire on a
   subsequent build after one day. No deployment credentials reach the builder.
4. A separate GitHub-hosted deploy job imports the finished store closure,
   joins as `tag:ci`, and uses SSH to activate it. Tailnet DNS is disabled on
   both runners; deploy SSH resolves the registry FQDN from the Tailscale peer
   map, so `tag:ci` only needs its existing SSH grant. Nix has `max-jobs = 0` and
   no builders on the runner; the exported deploy node has `remoteBuild = false`.
   Neither the runner nor the homeserver compiles deployment outputs.
5. Compare `/run/current-system` with the built system first. An unchanged
   closure exits without activation, including unrelated `home/**` or `lib/**`
   changes. Deploys are serialized with `cancel-in-progress: false`, so a new
   push never cancels an activating job.
6. For a changed closure, deploy-rs retains `magicRollback`, `autoRollback` and
   its confirmation timeout from `flake/deploy.nix`. Then verify the exact
   activated path, registry drift using inventory read from the activated host,
   failed units, AdGuard DNS over UDP/TCP, Prometheus readiness, Loki readiness
   and Grafana database health. Startup probes retry; exhaustion fails the run
   visibly. Functional health failures after activation confirmation do not
   automatically roll back; inspect the logs and use the normal rollback path.

The deploy job's secrets live in the `homeserver-gcp-deploy` environment:
`TS_OAUTH_DEPLOY_CLIENT_ID`, `TS_OAUTH_DEPLOY_SECRET` and
`HOMESERVER_DEPLOY_SSH_KEY`. The OAuth client has only the auth-keys write scope
for `tag:ci`; the SSH key's public half is authorized for the deploy user in
`hosts/homeserver-gcp/default.nix`, and must reach the host in a normal deploy
before the first workflow run. Never print key material.
The builder job uses only the existing builder secrets listed above.

After review, an owner must enable the workflow to dispatch it manually on
`main`, confirm `homeserver-gcp`, and inspect the builder/export/import,
activation, rollback confirmation and service checks. Exercise the unchanged
closure path with a second dispatch. Only leave automatic deployment enabled
after those live checks succeed; disable it again if they fail. Static tests
cannot establish credential validity, tailnet connectivity, artifact size/time,
or actual rollback and service behavior.

The self-hosted `github-runner-homeserver-deploy.service` remains a recovery
path only. No routine workflow job targets it. Its registration credential is
`github_runner_homeserver_deploy_token` in sops, a fine-grained PAT restricted
to this repository with Administration read/write. Rotate it with `sops`, apply
through the normal host maintenance process, and remove stale registrations
from GitHub settings. Recovery registration guidance lives in the
[host runbook](../hosts/homeserver-gcp/CLAUDE.md).

Merging to `main` and deployment credential access are root-equivalent on the
homeserver. The deployment environment can add required reviewers if desired.
This workflow never rolls out the `main` workstation or runs Terraform.

## Tailscale ACL Drift

The generated ACL artifact is also checked against the live tailnet policy by
`.github/workflows/tailscale-acl-drift.yml`, which runs
`bash scripts/check-tailscale-acl-drift.sh`.

Run it locally when changing `lib/acl.nix` or registry-owned Tailscale metadata:

```bash
bash scripts/check-tailscale-acl-drift.sh
```

Pushes to `main` that touch the ACL generator, host registry, workflow, or ACL
scripts run the same workflow in apply mode: it applies the rendered `tagOwners`
and `acls` to the live policy, then runs the drift check again. The daily
scheduled run remains detect-only so out-of-band console edits fail loudly
instead of being silently overwritten.

When the check reports drift, apply the rendered artifact with
`scripts/apply-tailscale-acl.sh` rather than pasting it into the admin console
or POSTing it directly — the rendered artifact contains only `{tagOwners,
acls}`, and a raw POST replaces the _entire_ live policy file, silently wiping
sections the generator does not own (`ssh`, `autoApprovers`, `nodeAttrs`,
`groups`, ...). The script fetches the live policy, overlays just `tagOwners`
and `acls` from the rendered artifact, and POSTs the merged result back guarded
by the live policy's `ETag`:

```bash
bash scripts/apply-tailscale-acl.sh --dry-run   # show the merged diff only
bash scripts/apply-tailscale-acl.sh             # fetch, merge, and apply
```

Requires `TAILSCALE_API_KEY` (read+write ACL access) and `TAILSCALE_TAILNET` in
the environment, same as the drift check.

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
the report artifact; vulnix advisories fail the workflow. This CI run is the sole
CVE signal: the live homeserver formerly ran an on-host `vulnix-scan` timer, but
vulnix's ~3 GB NVD working set OOM-killed the 3.8 GB host, so it was removed in
favour of the (strictly superior, gating, off-host) CI scan.

### CVE triage

- **Owner:** the operator (Filip) — single-maintainer flake, no rotation needed.
- **Trigger:** reactive, not a parallel calendar commitment. Triage happens
  when the scheduled weekly `cve-scan` workflow run fails (an advisory exists
  in a current `main`/`homeserver-gcp` closure), or a PR touching `flake.lock`
  fails its `cve-scan` gate. No new periodic review is added — the existing
  weekly schedule plus the PR gate are the only forcing functions, and GitHub's
  failed-run notification is the alert.
- **Triage path**, once a real advisory surfaces:
  1. Open the uploaded `cve-report` artifact, identify the affected
     package/derivation, and check whether it's actually reachable in the
     host's exposure model (cross-reference `docs/security.md` if relevant).
  2. **Patch:** bump the input (flake.lock update, override, or upstream fix)
     and re-run `bash scripts/validate.sh cve-reports` to confirm it clears.
  3. **Accept:** if no fix is available yet and the risk is judged acceptable,
     open a tracking issue recording the CVE id, affected package/host, the
     justification, and a re-check trigger (e.g. "next flake-lock bump" or a
     concrete date). Do **not** reintroduce a vulnix whitelist file — those
     were deliberately removed for causing false-positive churn (see
     `.agents/learning/candidates/archive/2026-06-06-vulnix-live-counts-are-noisy.yml`).
     The CI gate stays red/tracked until the underlying package is actually
     fixed; the tracking issue is the durable record of the deliberate,
     time-boxed override decision.
  4. **Track:** for advisories that need upstream movement (e.g. nixpkgs
     hasn't picked up a fix yet), the tracking issue from step 3 is the
     mechanism — no separate ledger.

### flake-update eval-failure triage

When a weekly `flake-update` PR fails `eval` (or another gate) after a
`flake.lock` bump, check for a self-documenting expiry condition before
digging into the failure from scratch:

```bash
grep -rni "drop this\|once upstream\|drop once" --include="*.nix" .
```

An override written to work around an upstream bug often names the exact
upstream commit that will obsolete it. A nixpkgs bump landing
that commit is the exact trigger that can flip the override's argument
signature and break eval — the comment is the fix, or at least the fastest
path to it, before treating the failure as a fresh investigation.

A module/package argument mismatch can also originate inside the pinned
nixpkgs revision: for example, its DisplayLink module passed `evdi` while the
package expected `linuxPackages`. Inspect the earliest failing job with
`gh run view <run-id> --log-failed`, then compare the module and package at the
revision recorded in `flake.lock`. If a temporary compatibility overlay is
needed, give it a clear removal condition. Evaluate the real `main` toplevel
as well as building `main-ci`: CI deliberately skips DisplayLink's unfree
hardware dependency, so its closure alone cannot catch this mismatch.

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

`scripts/validate.sh` subcommands, except `docs`, `tf-drift` and `cve-reports`,
run entirely on the on-demand `gcp-builder` VM. The script starts the VM
(idempotent), waits for SSH over Tailscale, and runs the command against a copy of
the checkout; the builder powers itself off after ~20 minutes idle. Use
`bash scripts/on-builder.sh <command>` for anything else, and `rebuild --remote`
to build `main` there. No manual start/stop is needed in the common
path.

The command runs locally when `USE_BUILDER=0` or the build key is not present
(CI, fresh clones, or a `main` without the wiring deployed), and after a warning
if the VM cannot be started or reached. So a cold builder only ever
adds a start-and-wait at the front of a heavy build; it never blocks an ordinary
`rebuild`, which is why the builder is deliberately not registered in
`nix.buildMachines`.

```bash
# Force a purely local build even on a deployed main:
USE_BUILDER=0 bash scripts/validate.sh hosts

# Override the builder location / parallelism:
BUILDER_MAXJOBS=8 bash scripts/validate.sh heavy
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

The default dev shell's `shellHook` execs `zsh` only for interactive sessions
(when `$-` contains `i`), so `nix develop --command <cmd>` runs `<cmd>`
normally and passes its stdout/exit status through. For automation (CI steps,
deploy scripts) you can still reach for a flake app/package directly or `nix
shell nixpkgs#tool -c <cmd>` when a tool isn't part of the dev shell — see
`nix shell nixpkgs#deploy-rs -c deploy` in the [Automated Homeserver
Deploy](#automated-homeserver-deploy) workflow.

## Desktop Apps

The desktop shell is built from the repo-local package at `packages/quiet-shell/`,
and Home Manager runs it as the `quiet-shell` user service.

```bash
nix build .#quiet-shell
systemctl --user restart quiet-shell
```

Its tests are in `tests/quiet-shell/`.

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

After editing `treefmt.nix`, the installed pre-commit `treefmt` wrapper can lag
the config for the rest of the session and keep formatting files the fresh
config now excludes. Trust the CI-equivalent commands — `nix fmt --
--fail-on-change` and `nix run .#statix -- check .` — over a stale hook. Only
re-`nix develop` (to regenerate the wrapper) or commit with `--no-verify` once
those fresh checks pass; never use `--no-verify` to skip a real failure.

The installed `.git/hooks/pre-commit` pins a specific `nix-store` path. After a
`nix-collect-garbage` reaps that path, `git commit` in the primary checkout
aborts with `/nix/store/...-pre-commit-<ver>/bin/pre-commit: No such file or
directory` and leaves the commit unmade with files still staged. This is
distinct from a fresh worktree that simply lacks a flake-generated
`.pre-commit-config.yaml` — here the config exists, only the hook's binary
path is dead. Re-run the commit through the dev shell — `nix develop -c git
commit -m ...` — whose `shellHook` reinstalls the hook against a live store
path and then runs the real checks. Do not reach for `--no-verify`: that skips
real lint on `.nix` changes, which is forbidden in the primary checkout.

### writeShellApplication Scripts Need a Real Build, Not Just Shellcheck

`pkgs.writeShellApplication` runs ShellCheck on the script text at build time
with no severity floor, so even an info-level warning (e.g. `SC2016` on an
intentional single-quoted body meant to expand in a _different_ shell, like an
`fzf --preview` command or an `awk`/`perl` one-liner) fails the derivation.
`bash -n script.sh` and a standalone `shellcheck script.sh` both pass locally
and mask this — only building the actual `writeShellApplication` derivation
reproduces the failure:

```bash
nix build '.#checks.x86_64-linux.<name>'   # or the package/home.nix target that wraps it
```

For an intentional non-expansion, add an explicit
`# shellcheck disable=SC2016` at the site rather than relying on severity
filtering — there isn't one here.

### Markdown Prose And Prettier

Prettier (via `nix fmt`) rewrites bare underscores in Markdown prose into
escaped emphasis markers (`authorized_keys` → `authorized\_keys`,
`_patterns_` → `\_patterns_`). A local `nix fmt` can report no changes for an
unrelated reason and still leave this drift for CI's `nix fmt --
--fail-on-change` to catch, failing lint on an otherwise docs-only PR.
Backtick identifiers containing underscores (`` `authorized_keys` ``) instead
of writing them as bare prose, and run `nix fmt -- --fail-on-change` (not just
`nix fmt`) before opening a docs PR.
