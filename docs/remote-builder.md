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
   so ordinary fresh clones are unaffected. PR CI supplies its existing dedicated key as described below.
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

| Variable          | Default                              | Effect                                                                 |
| :---------------- | :----------------------------------- | :--------------------------------------------------------------------- |
| `USE_BUILDER`     | `1`                                  | Set `0` to run `validate.sh` locally.                                  |
| `BUILDER_ZONE`    | found automatically                  | GCE zone of the builder VM; it can move on a capacity shortage.        |
| `BUILDER_SSH_KEY` | `/run/secrets/gcp_builder_build_key` | Override the caller’s SSH private-key file (CI uses a temporary file). |
| `BUILDER_FQDN`    | `gcp-builder.<tailnet>.ts.net`       | Tailnet name of the builder.                                           |
| `BUILDER_MAXJOBS` | `8`                                  | Remote `maxjobs` passed to `--builders` by `rebuild`.                  |

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
- **Disposable builder.** The builder holds no sops secrets, no service state,
  and no backup. Its only secret beyond the tailnet key is the ntfy topic URL for
  prebuild notifications, which can only post to that topic. Losing the builder
  costs only provisioning time, which is why a changed host key after
  reprovisioning is tolerated with `accept-new`.

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
waits for the next Friday or a manual
`sudo systemctl start builder-prebuild` on the builder.

A timer runs `builder-prebuild.service` as `user` at 20:17 UTC on Fridays, once
the scheduled start has had time to land, so ordinary on-demand boots do not
start a full build. It resolves the
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
job stops with `missing-displaylink`, giving the expected store path.
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
change its expected name/hash. A new version needs seeding again. The
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

## Pull-request CI on the builder

The `builder` job in `.github/workflows/nix.yml` is a coordinator on a
**GitHub-hosted Ubuntu runner**. No GitHub runner is installed on the builder.
Only same-repository `pull_request` events with heavy checks selected by
`scripts/ci-plan.sh` may use it. Fork PRs never enter the credential-bearing job,
and docs-only plans do not authenticate, join the tailnet or start the VM.
The `skip-builder` PR label opts out; adding/removing it triggers a fresh run.
Push and merge-group events retain the existing GitHub-hosted jobs.
Evaluation and lint always retain their existing GitHub-hosted jobs.

The job uses existing repository secrets `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`,
`BUILDER_CI_SSH_KEY` and `BUILDER_CI_GCP_KEY`. The SHA-pinned Tailscale action
joins with `tag:ci-builder` and `--accept-dns=false`: this tag reaches only the
builder's SSH port and cannot reach the tailnet resolver. `BUILDER_FQDN` is
therefore set to the builder's tailnet IP, `100.106.144.121`. The existing
GCP service account can manage only that VM. The shared startup/SSH probe in
`scripts/lib/builder.sh` is reused, with `BUILDER_SSH_KEY` pointing to a mode-0600
file under the runner's temporary directory. It is deleted even on failure;
Google authentication and Tailscale also perform their own credential cleanup.
No credential creation, ACL change or deployment is part of this workflow.

Once the probe succeeds, `scripts/on-builder.sh` transfers only tracked files
and invokes `scripts/ci-builder-checks.sh` with the planner's selectors and
matrices. No repository checkout credentials or cloud/SSH keys are transferred.
A minimal pinned-input Nix shell supplies Git and jq; a fresh local Git index
lets Git-dependent preflight checks inspect the transferred snapshot. It has
no remote and no push credentials.

Only planned light checks, packages, hosts and VM tests run, with up to four
commands in flight across those families. Each command calls
`scripts/validate.sh` with `ON_BUILDER=1`, writes a separate temporary log and
has its exact exit status joined. Failed logs are printed; successful commands
print their name and duration. Every planned command is attempted even when
another fails. The job fails if any check fails, or SSH/transfer is lost after
the successful readiness probe. Logs and the temporary checkout are cleaned up
afterward; the Nix store persists. Commands run under Bash with `-euo pipefail`;
there is no success-masking pipeline around the validation command.

Failure to authenticate, start or reach the builder **before checks start**
sets `available=false` and runs the original GitHub-hosted heavy jobs. A check
failure never becomes an unavailable result and never triggers fallback.
The merge gate accepts either a successful, completed builder job with skipped
heavy jobs, or every heavy job selected by the original plan passing on GitHub.
Cancelled jobs, missing completion output, failed checks, failed evaluation or
failed lint cannot satisfy the gate. Deterministic tests cover these cases,
concurrent execution, keep-going behavior, malformed plans and docs-only plans:

```bash
bash scripts/test-ci-builder.sh
bash scripts/validate.sh light
```

### PR code is trusted code execution on this machine

Same-repository PR code runs directly as the builder's trusted Nix user, with
root-equivalent privileges. It can read/change the persistent builder state and
influence outputs later consumed by other callers. Review same-repository PR
branches accordingly; never run fork code through this job. Keep **nothing
valuable** on the builder: no service state, backup, production credentials,
repository write tokens or private user data. Treat its store and temporary
workspaces as disposable, and reprovision after suspected compromise. The
`skip-builder` label selects the isolated GitHub-hosted path when appropriate;
it is an operational opt-out, not a sandbox for untrusted code on the builder.
