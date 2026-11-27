# gcp-builder Host

On-demand GCP Nix remote builder. Normally **powered off**; `main` starts it
transparently for heavy builds and it powers itself off when idle. Disposable:
no persistent service state, no sops secrets, no backup. One hand-seeded file
holds the prebuild notification URL (see below).

Status: **active** (provisioned once, then start/stop on demand).

For the pattern overview (lifecycle, offload design, trust boundary, and reuse
scope) see [`docs/remote-builder.md`](../../docs/remote-builder.md). This file is
the host-local provisioning runbook.

## What it is / isn't

- **Is:** a headless `n2-custom-14-32768` (14 vCPU, 32 GB, nested
  virtualization enabled) that builds Nix closures and runs the KVM-backed
  nixos test suite offloaded from `main`. It also runs `on-worker` batch jobs
  (see [Batch jobs](#batch-jobs)).
- **Isn't:** a service host. No AdGuard/LGTM/nginx, no backups, no
  Home Manager, no sops. Losing it costs nothing but provisioning time.

## How `main` uses it

- `main` carries a dedicated build key (`root`'s nix-daemon → trusted `user@`
  here): private half is sops-encrypted at
  `hosts/main/secrets/gcp_builder_build_key.enc`, public half is authorized in
  `hosts/gcp-builder/default.nix`.
- `nix.buildMachines` is intentionally **not** set on `main` — that would
  make every ordinary build pay an SSH-connect timeout while the builder is off.
  Instead `scripts/validate.sh` starts the VM (via `gcloud`, falling back
  to `nix shell nixpkgs#google-cloud-sdk -c gcloud` if `gcloud` isn't on `PATH`),
  waits for SSH over Tailscale, and runs the whole command on it. See
  [`docs/remote-builder.md`](../../docs/remote-builder.md).
- Knobs: `USE_BUILDER=0` disables offload; `BUILDER_ZONE`, `BUILDER_FQDN`, `BUILDER_USER`,
  `BUILDER_MAXJOBS` override defaults. Commands run locally when the caller's build
  key isn't present (CI, fresh clones), and after a warning if the VM can't be
  started or reached.
- **Prerequisite:** the calling host's `gcloud` (or `nix shell` fallback) must be
  authenticated, with the builder's project active
  (`gcloud config set project <id>`).

## Batch jobs

Since #592 this VM also runs `on-worker` jobs (long CPU-heavy work from any
repository), so builds and jobs share it instead of taking turns under the
project's 16-vCPU `CPUS_ALL_REGIONS` cap (14 here plus 1 for the homeserver).
The role is `profiles.batchJobs` in `modules/nixos/profiles/batch-jobs`.

```bash
cd ~/code/some-repo
on-worker run -n calib -- uv run python scripts/calibrate.py --workers 14
on-worker status            # every job, newest first
on-worker logs -f calib     # follow; exits with the job's status
on-worker pull results/     # copy outputs back into this checkout
on-worker run -w -- make test   # wait in the foreground
```

- Jobs run as `jobs`, which has no sudo and no Nix daemon trust (the
  `on-worker jobs user stays unprivileged` invariant). `user` here is
  root-equivalent, and the `ci-builder` runners reach it, so treat job
  workspaces as readable by this repo's CI.
- **Sharing the CPUs.** `nix-daemon` runs at `CPUWeight=20` against the jobs
  user's slice at 100. While both are busy, builds get about a sixth of the
  CPUs; when either is idle, the other gets the whole VM. A deploy during a
  long job is slower, not blocked.
- The checkout's tracked files plus untracked, non-ignored files are synced to
  `~jobs/work/<repo>-<hash>`, which persists between runs (`.venv`, caches).
  Add gitignored inputs with `-i PATH`. Symlinks that point outside the
  checkout are copied as their targets. Sync never deletes remote files.
- Jobs are `systemd-run --user` units named `worker-job-<name>`, bounded by
  `--max-runtime` (default 24h). Logs, command and exit status live in
  `~jobs/jobs/<name>/`. A finished job posts to the private ntfy topic.
- `on-worker down` refuses while a job or a Nix build runs (`-f` overrides).
- on-worker starts and stops the VM with `scripts/lib/builder.sh`, included at
  build time, so it also moves the VM out of a full zone and resumes an
  interrupted move. It waits up to `ON_WORKER_QUOTA_WAIT` (1800 s) for CPU quota.
- `network-doctor worker`, run as `jobs`, checks DNS and the PyPI index.

## Idle auto-shutdown

`builder-idle-shutdown.timer` (in `default.nix`) checks every 5 min and powers
the box off after 20 min with no established port-22 connection (no session, no
in-flight distributed build), no running boot prebuild and no running
`worker-job-*` unit. The stamp lives in `/run`, so a fresh boot gets a
full grace window before the first check.

## Zone moves

If `start_builder` (validate.sh, on-builder.sh, `rebuild --remote`, on-worker)
finds the VM's zone out of capacity, it test-creates a VM in
another `europe-west2` zone, snapshots the disk as `gcp-builder-move`, deletes the
old VM and recreates it there. The regional SSD quota cannot hold two copies of
the disk, which is why the order is fixed. The address, cache and DisplayLink file
all travel with the disk, and the VM stays in the new zone. If a move dies
partway, the next start resumes from the snapshot once it is 30 minutes old.

CI can do this through the `ciBuilderMove` role, conditioned on `gcp-builder`
resources (`infra/builder.tf`). Terraform no longer manages the VM itself. To
reprovision from nothing, restore the `google_compute_instance.gcp_builder`
resource from git history and drop its `removed` block.

## Prebuild notification

`builder-prebuild` posts "ready" or "failed" to the private ntfy topic when it
finishes, and the laptop shows it (`home/profiles/ntfy-notifications.nix`). The
topic URL is the builder's one secret outside Nix: a `user`-owned `0600` file at
`/var/lib/builder-prebuilt/notify-url`, seeded by hand. Anyone holding it can
only post to that topic. Without the file the job stays quiet, so reseed it
after reprovisioning:

```bash
sops -d --extract '["topic_url"]' home/users/user/secrets/ntfy.yaml |
  ssh user@gcp-builder 'umask 077; cat > /var/lib/builder-prebuilt/notify-url'
```

## Provisioning (operator-only, one time)

The builder is sops-free. SSH is tailnet-only, so it **must auto-join the tailnet
on boot** via an auth key (a host you cannot log into cannot run `tailscale up`,
and there is no console password). The key is dropped into the installed root
with `nixos-anywhere --extra-files`; it never enters the Nix store, git, or
Terraform state.

1. **tfvars** — ensure `infra/terraform.tfvars` has `gcp_project` and
   `bootstrap_ssh_public_key` (shared with the homeserver flow).

2. **Mint a Tailscale auth key** — Tailscale admin → Settings → Keys → Generate:
   **reusable**, **non-ephemeral**, **pre-approved**, and **tagged `tag:builder`**.
   Non-ephemeral matters: the builder is powered off most of the time, and an
   ephemeral node would be deregistered while down and lose its stable
   `gcp-builder.<tailnet>.ts.net` name. The `tag:builder` tag means the existing
   `tag:workstation → tag:builder:22` ACL rule already grants `main` SSH — no ACL
   change needed. Stage it for `--extra-files`:

   ```bash
   umask 077
   mkdir -p /tmp/builder-extra/var/lib
   printf 'tskey-auth-XXXX' > /tmp/builder-extra/var/lib/tailscale-authkey
   ```

3. **Create the VM** — restore the Terraform resource (see Zone moves), then
   `cd infra && tofu plan && tofu apply`. Review the plan
   before applying (the disk-type/`desired_status` pins keep the live homeserver
   from being replaced).

4. **Temporary SSH path** — the network-wide `deny_public_ssh` rule blocks public
   TCP/22, so open a scoped, higher-priority hole to the builder for install:

   ```bash
   gcloud compute firewall-rules create gcp-builder-provision-ssh \
     --network=default --direction=INGRESS --action=ALLOW \
     --rules=tcp:22 --target-tags=gcp-builder --priority=400 \
     --source-ranges="$(curl -fsS ifconfig.me)/32"
   ```

5. **Install NixOS** — over the bootstrap account (NOPASSWD sudo), placing the
   auth key into the installed root. Use ssh-agent auth (don't pass `-i` with a
   passphrase-protected key — nixos-anywhere loads the raw file non-interactively
   and fails):

   ```bash
   IP=$(gcloud compute instances list --filter=name=gcp-builder --format="value(networkInterfaces[0].accessConfigs[0].natIP)")
   nix run github:nix-community/nixos-anywhere -- --flake .#gcp-builder \
     --target-host "bootstrap@$IP" \
     --extra-files /tmp/builder-extra \
     --ssh-option StrictHostKeyChecking=accept-new
   ```

   On reboot the builder reads `/var/lib/tailscale-authkey` and joins the tailnet
   as `tag:builder` automatically — no manual `tailscale up`.

6. **Verify + lock down** — confirm it joined, remove bootstrap metadata, scrub
   the staged key, remove the temporary hole:

   ```bash
   BUILDER=gcp-builder
   ZONE=$(gcloud compute instances list --filter=name=gcp-builder --format="value(zone.basename())")
   BOOTSTRAP_METADATA_KEYS=(
     "bootstrap-ssh-public-key"
     "startup-script"
   )

   tailscale status | grep gcp-builder
   for metadata_key in "${BOOTSTRAP_METADATA_KEYS[@]}"; do
     gcloud compute instances remove-metadata "$BUILDER" \
       --zone "$ZONE" \
       --keys "$metadata_key" >/dev/null || true
   done
   remaining_metadata_keys="$(
     gcloud compute instances describe "$BUILDER" \
       --zone "$ZONE" \
       --flatten='metadata.items[]' \
       --format='value(metadata.items.key)'
   )"
   for metadata_key in "${BOOTSTRAP_METADATA_KEYS[@]}"; do
     if grep -Fxq "$metadata_key" <<<"$remaining_metadata_keys"; then
       echo "bootstrap metadata key still present: ${metadata_key}" >&2
       exit 1
     fi
   done
   shred -u /tmp/builder-extra/var/lib/tailscale-authkey
   gcloud compute firewall-rules delete gcp-builder-provision-ssh --quiet
   ```

7. **Deploy the wiring to `main`** — `nh os switch --hostname main .` so the build
   key and ssh policy land, then confirm an offloaded build:

   ```bash
   gcloud compute instances stop gcp-builder --zone "$ZONE"   # prove cold start
   bash scripts/validate.sh host homeserver-gcp
   # expect: "remote builder: gcp-builder ready"
   ```

## Build key rotation

The build link key is low-stakes and rotatable:

1. `ssh-keygen -t ed25519 -f /tmp/k -N "" -C nix-remote-build-main-to-gcp-builder`
2. Encrypt the private half (recipients picked from `.sops.yaml`):
   `sops -e --input-type binary --output-type binary --filename-override \
hosts/main/secrets/gcp_builder_build_key.enc /tmp/k > hosts/main/secrets/gcp_builder_build_key.enc`
3. Replace the public key in `hosts/gcp-builder/default.nix`, `shred -u /tmp/k`.
4. Redeploy `main` and `gcp-builder`.

## Gotchas

- **Reprovisioning changes the SSH host key.** `main` uses `accept-new` for the
  builder, so a changed key is rejected until the stale `known_hosts` entry is
  cleared — reboot `main` (its `/root` is ephemeral) or remove the entry.
- **nested virtualization is required** for the KVM test suite — keep the machine
  type in the `n2`/`n2d`/`c3` families; `e2` cannot run booted nixos tests.
- **Not a spot instance** — a preemptible reclaim would kill long `heavy` runs.
  Power state is start/stop only; never let Terraform manage `desired_status`.
- **No console password** — recover a wedged builder by reprovisioning, not via
  serial console.
