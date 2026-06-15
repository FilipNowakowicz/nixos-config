# gcp-builder Host

On-demand GCP Nix remote builder. Normally **powered off**; `main` starts it
transparently for heavy builds and it powers itself off when idle. Disposable:
no persistent service state, no sops secrets, no backup.

Status: **active** (provisioned once, then start/stop on demand).

For the pattern overview (lifecycle, offload design, trust boundary, and reuse
scope) see [`docs/remote-builder.md`](../../docs/remote-builder.md). This file is
the host-local provisioning runbook.

## What it is / isn't

- **Is:** a headless `n2-standard-4` (nested virtualization enabled) that builds
  Nix closures and runs the KVM-backed nixos test suite offloaded from `main`.
- **Isn't:** a service host. No Vaultwarden/AdGuard/LGTM/nginx, no backups, no
  Home Manager, no sops. Losing it costs nothing but provisioning time.

## How `main` (and `gcp-agent`) use it

- `main` carries a dedicated build key (`root`'s nix-daemon → trusted `user@`
  here): private half is sops-encrypted at
  `hosts/main/secrets/gcp_builder_build_key.enc`, public half is authorized in
  `hosts/gcp-builder/default.nix`.
- `gcp-agent` carries its own, independently-revocable build key (same
  mechanism, see `hosts/gcp-agent/nix-remote-build.nix`): private half at
  `hosts/gcp-agent/secrets/gcp_builder_build_key.enc`, public half also
  authorized in `hosts/gcp-builder/default.nix`. This lets `gcp-agent`'s
  unattended sessions offload heavy `scripts/validate.sh` tiers the same way
  `main` does, without sharing a credential with `main` (#304).
- `nix.buildMachines` is intentionally **not** set on either caller — that would
  make every ordinary build pay an SSH-connect timeout while the builder is off.
  Instead `scripts/validate.sh` (`host`/`hosts`/`heavy`/`profile-test(s)`/
  `smoke-*`) calls `ensure_builder`: it starts the VM (via `gcloud`, falling back
  to `nix shell nixpkgs#google-cloud-sdk -c gcloud` if `gcloud` isn't on `PATH`),
  waits for SSH over Tailscale, and passes `--builders` for that one invocation.
- Knobs: `USE_BUILDER=0` disables offload; `BUILDER_ZONE`, `BUILDER_FQDN`,
  `BUILDER_MAXJOBS` override defaults. Offload is a silent no-op (local build)
  when neither `gcloud` nor `nix` is available, or the caller's build key isn't
  present (CI, fresh clones).
- **Prerequisite:** the calling host's `gcloud` (or `nix shell` fallback) must be
  authenticated, with the builder's project active
  (`gcloud config set project <id>`).

## Idle auto-shutdown

`builder-idle-shutdown.timer` (in `default.nix`) checks every 5 min and powers
the box off after 20 min with no established port-22 connection (no session, no
in-flight distributed build). The stamp lives in `/run`, so a fresh boot gets a
full grace window before the first check.

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

3. **Create the VM** — `cd infra && tofu plan && tofu apply`. Review the plan
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
   IP=$(cd infra && tofu output -raw builder_external_ip)
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
   BUILDER=$(cd infra && tofu output -raw builder_name)
   ZONE=$(cd infra && tofu output -raw instance_zone)
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
   # expect: "remote builder: gcp-builder ready; offloading builds"
   # and nix logging: building '…' on 'ssh-ng://user@gcp-builder.…'
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
