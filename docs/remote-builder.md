# On-Demand Remote Builder Pattern

This repository runs a real on-demand Nix remote builder: `gcp-builder` is a
cloud VM that is **normally powered off**, started transparently by `main` for
heavy builds, and powers itself off again when idle. This page documents that
pattern — what it is, how the offload works, and the trust boundary it relies on
— so the lifecycle is legible without reading three files at once.

It is a documented pattern, not a generic package. The implementation is
GCP- and tailnet-specific by design; see [Scope and reuse boundary](#scope-and-reuse-boundary).

The operational how-to (knobs, cold-start expectation, when offload kicks in)
lives in [`docs/operations.md`](operations.md#on-demand-remote-builder); the
provisioning runbook and gotchas live in
[`hosts/gcp-builder/CLAUDE.md`](../hosts/gcp-builder/CLAUDE.md). This page is the
pattern writeup that ties them together.

---

## The pattern in one sentence

Keep the builder powered off, start it on demand only for the commands that
benefit, pass `--builders` for that single invocation rather than registering a
global build machine, and let the builder shut itself down when no one is using
it — so a workstation gets cloud-scale build capacity without paying for an
always-on machine or an SSH-timeout tax on every ordinary rebuild.

## Why not `nix.buildMachines`

The obvious approach — register the builder in `nix.buildMachines` on `main` — is
deliberately **not** used. The builder is off most of the time, so a global build
machine would make every ordinary `rebuild` pay an SSH-connect timeout before
falling back to local. Instead the offload is opt-in per invocation: only the
heavy commands in `scripts/validate.sh` start the VM and pass `--builders` for
that one build.

`hosts/main/nix-remote-build.nix` therefore provides only the pieces that must
live in the system configuration, not a global build machine:

- the decrypted private build key (`sops.secrets.gcp_builder_build_key`, mode
  `0400`, read by root's nix-daemon);
- root's host-key policy for the builder (`StrictHostKeyChecking accept-new`,
  acceptable because connections ride authenticated Tailscale WireGuard and the
  builder's host key is only created at provisioning);
- `nix.settings.builders-use-substitutes = true`, so the builder pulls
  dependencies straight from the binary caches instead of `main` copying every
  input over SSH.

## Lifecycle

The offload is driven by `ensure_builder` in `scripts/validate.sh`, invoked by the
build-heavy subcommands (`host`, `hosts`, `heavy`, `profile-test(s)`, `smoke-*`):

1. **Gate.** Offload runs only when it can help: `USE_BUILDER != 0`, `gcloud` is
   on `PATH`, and the build key exists at `/run/secrets/gcp_builder_build_key`
   (present only on a deployed `main`). If any check fails it is a silent no-op
   and the build runs locally — so CI and fresh clones are unaffected.
2. **Start.** `gcloud compute instances start gcp-builder` (idempotent). If the
   VM cannot be started — wrong project, missing auth — it logs and falls back to
   a local build rather than failing the command.
3. **Wait.** A readiness probe SSHes over the tailnet (`user@<builder-fqdn>`) with
   a bounded retry (~2 min) until the box answers. The probe uses the caller's own
   SSH key; the build itself uses the root-only build key under `--builders`.
4. **Offload.** On success the build appends
   `--builders "ssh-ng://user@<fqdn> x86_64-linux <key> <maxjobs> 2 <features>"`,
   with `features = kvm,nixos-test,big-parallel,benchmark` so the KVM-backed
   nixos test suite can run remotely.
5. **Self-shutdown.** `builder-idle-shutdown.timer` on the builder checks every
   5 minutes and powers the box off after 20 minutes with no established port-22
   connection (no interactive session and no in-flight distributed build). The
   idle stamp lives in `/run` (tmpfs), so a fresh boot gets a full grace window
   before the first check.

Net effect: a heavy `bash scripts/validate.sh hosts` cold-starts the builder,
offloads, and the builder powers itself back off ~20 minutes after the last build
finishes — no manual start/stop in the common path.

## Knobs

| Variable          | Default                        | Effect                                   |
| :---------------- | :----------------------------- | :--------------------------------------- |
| `USE_BUILDER`     | `1`                            | Set `0` to force a local build.          |
| `BUILDER_ZONE`    | `europe-west2-a`               | GCE zone of the builder VM.              |
| `BUILDER_FQDN`    | `gcp-builder.<tailnet>.ts.net` | Tailnet name the offload connects to.    |
| `BUILDER_MAXJOBS` | `8`                            | Remote `maxjobs` passed to `--builders`. |

Prerequisite: `gcloud` on `main` must be authenticated with the builder's project
as its active config (`gcloud config set project <id>`).

## Trust boundary

The builder is a trusted Nix remote builder, which has a real security
consequence: a trusted builder can influence the store paths `main` realises, so
SSH access to it is effectively root-equivalent on `main`'s build outputs. The
boundary is kept tight accordingly:

- **Tailnet-only, key-only.** SSH to the builder is reachable only over Tailscale
  (`tag:server`; the existing `tag:workstation → tag:server:22` ACL grants `main`
  without a bespoke rule). There is no public TCP/22 — a network-wide
  `deny_public_ssh` rule blocks it, and provisioning opens only a scoped,
  source-pinned, temporary hole that is removed afterward.
- **Dedicated build key.** The `main → gcp-builder` link uses its own ed25519 key
  (`hosts/main/secrets/gcp_builder_build_key.enc`), separate from personal SSH
  keys, and is low-stakes/rotatable (rotation steps in the host runbook).
- **Disposable, secret-free builder.** The builder holds no sops secrets, no
  service state, and no backup. Losing it costs only provisioning time, which is
  why a changed host key after reprovisioning is tolerated with `accept-new`.

## Scope and reuse boundary

This is intentionally a documented pattern, not a generalized module. The
implementation hard-codes GCP (`gcloud compute instances start`), a specific zone,
and a tailnet FQDN; promoting it to a generic multi-cloud or multi-builder
abstraction now would mean inventing options no second consumer exists to
validate. The reusable _idea_ is portable — power off by default, start on demand,
offload per-invocation instead of via `nix.buildMachines`, self-shutdown on idle —
but the code stays host-specific until a second builder or a non-GCP backend
actually appears. Extract helpers only then.

## See also

- [`docs/operations.md`](operations.md#on-demand-remote-builder) — operational
  knobs and validation offload behaviour.
- [`hosts/gcp-builder/CLAUDE.md`](../hosts/gcp-builder/CLAUDE.md) — provisioning
  runbook, idle-shutdown details, build-key rotation, and gotchas.
- `hosts/main/nix-remote-build.nix` — the consumer-side system wiring on `main`.
- `scripts/validate.sh` — the `ensure_builder` offload implementation.
