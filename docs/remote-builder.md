# On-Demand Remote Builder Pattern

This repository runs a real on-demand Nix remote builder: `gcp-builder` is a
cloud VM that is **normally powered off**, started transparently by `main` (and
by `gcp-agent`, for unattended issue-loop sessions) for heavy builds, and powers
itself off again when idle. This page documents that pattern — what it is, how
the offload works, and the trust boundary it relies on — so the lifecycle is
legible without reading three files at once.

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
benefit, run those commands on it rather than registering a global build machine,
and let the builder shut itself down when no one is using
it — so a workstation gets cloud-scale build capacity without paying for an
always-on machine or an SSH-timeout tax on every ordinary rebuild.

## Why not `nix.buildMachines`

The obvious approach — register the builder in `nix.buildMachines` on `main` — is
deliberately **not** used. The builder is off most of the time, so a global build
machine would make every ordinary `rebuild` pay an SSH-connect timeout before
falling back to local. Instead the offload is per invocation: `scripts/validate.sh`
and `rebuild --remote` start the VM when they need it.

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

`scripts/validate.sh` runs every subcommand on the builder except `docs`,
`tf-drift` and `cve-reports`. For anything else, use
`bash scripts/on-builder.sh <command>`. The shared steps are in
`scripts/lib/builder.sh`:

1. **Gate.** Offload runs when `USE_BUILDER != 0` and the build key exists at
   `/run/secrets/gcp_builder_build_key` (present only on a deployed `main` or
   `gcp-agent`, each with their own dedicated key — see
   [Trust boundary](#trust-boundary)). Without the key the command runs locally,
   so CI and fresh clones are unaffected.
2. **Start.** `gcloud compute instances start gcp-builder` (idempotent), falling
   back to `nix shell nixpkgs#google-cloud-sdk -c gcloud` if `gcloud` isn't on
   `PATH`. `validate.sh` prints a warning and runs locally if the VM cannot be
   started or reached. `on-builder.sh` fails instead.
3. **Wait.** A readiness probe SSHes over the tailnet (`user@<builder-fqdn>`) with
   a bounded retry (~2 min) until the box answers.
4. **Copy.** The files Git tracks, with their current contents, go to a new
   directory under `~/work`. Only encrypted secrets are in that set, and ignored
   files such as `infra/terraform.tfvars` stay behind.
5. **Run.** The command runs there, including evaluation, with its output and exit
   status passed back. Results stay on the builder.
6. **Self-shutdown.** `builder-idle-shutdown.timer` on the builder checks every
   5 minutes and powers the box off after 20 minutes with no established port-22
   connection. The idle stamp lives in `/run` (tmpfs), so a fresh boot gets a full
   grace window before the first check.

`rebuild --remote` is the exception, because `main` needs the finished system. It
evaluates locally, passes `--max-jobs 0` and `--builders` for that one invocation
so that every build step runs on the builder, and copies the closure back.
`sudo nixos-switch-main --remote` does the same for agents, after
`bash scripts/on-builder.sh true` has started the VM.

## Knobs

| Variable          | Default                        | Effect                                                |
| :---------------- | :----------------------------- | :---------------------------------------------------- |
| `USE_BUILDER`     | `1`                            | Set `0` to run `validate.sh` locally.                 |
| `BUILDER_ZONE`    | `europe-west2-a`               | GCE zone of the builder VM.                           |
| `BUILDER_FQDN`    | `gcp-builder.<tailnet>.ts.net` | Tailnet name of the builder.                          |
| `BUILDER_MAXJOBS` | `8`                            | Remote `maxjobs` passed to `--builders` by `rebuild`. |

Prerequisite: `gcloud` on `main` must be authenticated with the builder's project
as its active config (`gcloud config set project <id>`).

An agent's plain `nix build` or `nix flake check` is denied by
`.claude/hooks/guard-bash.sh` on hosts that can offload. Dry runs and
`--max-jobs 0` builds are allowed, and `LOCAL_BUILD=1` overrides it.

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
- **Dedicated, per-caller build keys.** The `main → gcp-builder` link uses its
  own ed25519 key (`hosts/main/secrets/gcp_builder_build_key.enc`), separate
  from personal SSH keys. `gcp-agent → gcp-builder` uses a second, independent
  key (`hosts/gcp-agent/secrets/gcp_builder_build_key.enc`,
  `hosts/gcp-agent/nix-remote-build.nix`): a compromised agent session cannot
  reuse `main`'s credential, and either key can be revoked without affecting the
  other. Both are low-stakes/rotatable (rotation steps in the builder runbook).
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
- [`hosts/gcp-agent/CLAUDE.md`](../hosts/gcp-agent/CLAUDE.md) — `gcp-agent`'s
  offload wiring and the operator follow-ups needed to make it live.
- `hosts/main/nix-remote-build.nix` / `hosts/gcp-agent/nix-remote-build.nix` —
  the consumer-side system wiring on each caller.
- `scripts/lib/builder.sh`, `scripts/on-builder.sh`, `scripts/validate.sh` and
  `scripts/rebuild-remote.sh` — the offload implementation.

## Weekly prebuilt workstation update

The public repository's Friday lock-update job starts at 18:00 UTC and can
merge later depending on CI. The GCE instance schedule in `infra/builder.tf`
starts `gcp-builder` Fridays around 20:00 UTC. This schedule needs the Compute
Engine service agent's project-level `roles/compute.instanceAdmin.v1` binding
included there. It is configuration only until an operator reviews/applies it;
this feature does not deploy Terraform or the builder configuration itself.
GCE schedules do not restart an already-running instance. A merge after 20:00
will therefore wait for another boot or a manual service restart.

Every builder boot runs `builder-prebuild.service` as `user`. It resolves the
latest public `main` revision and builds the full
`nixosConfigurations.main.config.system.build.toplevel` at that immutable
revision, without checkout credentials. `/var/lib/builder-prebuilt/system` is an
indirect GC root retaining the completed closure; `displaylink-source` roots the
manually seeded source. `/var/lib/builder-prebuilt/status.json` is atomically
replaced with `revision`, `store_path`, `result`, UTC `timestamp`, and `error`.
Results include `building`, `success`, `failed`, `missing-displaylink`, and
`timeout`. A failed attempt invalidates the previous successful status even if
the old rooted system still exists. The service is capped at three hours plus
30 seconds to terminate. Idle shutdown counts the service as busy while it is
activating/running/stopping, then resumes its normal 20-minute idle window.
No unattended activation happens on the laptop.

### Seed the private DisplayLink source

The full workstation closure needs the unfree DisplayLink `requireFile` source.
The builder cannot download it or publish it to a public cache. If absent, the
boot job stops with `missing-displaylink`, giving the expected store path.
After accepting the vendor terms and adding the correct blob to the laptop's
store (see [DisplayLink instructions](../.claude/main/displaylink.md)), an
operator can seed **only the private builder**, without any public cache:

```bash
bash scripts/on-builder.sh true
blob=$(nix eval --raw .#nixosConfigurations.main.pkgs.displaylink.src)
nix path-info "$blob"  # must already be present in the laptop store
nix copy --to ssh-ng://user@gcp-builder.tail90fc7a.ts.net "$blob"
ssh user@gcp-builder.tail90fc7a.ts.net sudo systemctl restart builder-prebuild.service
```

Use the latest `origin/main` checkout to resolve the source: a lock update may
change its expected name/hash. A new version needs seeding again. The boot
service roots the source after finding it; restarting it promptly avoids a GC
window. These commands are operator steps, not part of CI or Terraform apply.
No proprietary source or resulting unfree closure may be uploaded publicly.

### Activate on demand

From the local repo, fetch `origin` before deciding to update, then run
`rebuild --prebuilt`. The shell function starts/reaches the builder, reads its
status, and requires a successful `main` closure at exactly the local checkout's
`origin/main` revision. Exact equality deliberately rejects both older and
unrecognized newer revisions. A failed, still-building, missing, or malformed
status cannot activate anything. The client rechecks the tracking ref after
copying, imports the system closure with `nix copy --from ssh-ng://user@… --no-check-sigs`,
checks the activation executable, sets `/nix/var/nix/profiles/system` using
`sudo nix-env`, and invokes `switch-to-configuration switch`. It builds nothing
locally. It operates only on `main`, accepts no extra arguments, and does not
apply uncommitted local edits. Ordinary `rebuild` and `rebuild --remote` retain
their current behavior. Sudo still requires the workstation's normal permission;
an activation failure needs operator review and is not automatically retried.

The copy accepts unsigned outputs only from the dedicated authenticated builder,
which already has root-equivalent trust in the existing distributed-build model.
It does not disable signature checking globally or publish anything to a cache.

The builder has no notification credentials. Status can be inspected over the
existing authenticated SSH channel (`cat /var/lib/builder-prebuilt/status.json`);
notification delivery is intentionally left for a separate decision.
