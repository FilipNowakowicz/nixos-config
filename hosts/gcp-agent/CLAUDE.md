# gcp-agent Host

On-demand GCP host for running **Claude Code issue-loop sessions** (not Nix
builds). Normally **powered off**; started for a session and powers itself off
when idle. Disposable: state is a repo clone + nix store, recoverable by
reprovisioning, so no backup. Unlike `gcp-builder` it **carries sops secrets**
(its own `claude` login + a scoped GitHub PAT) and keeps **narrow sudo**.

Status: **provisioning** (registry + closure + sops wiring landed in #167;
operator provisioning steps below are run once).

This is the host-local provisioning runbook. The closest analog is
[`hosts/gcp-builder/CLAUDE.md`](../gcp-builder/CLAUDE.md) — read it for the
shared on-demand-VM mechanics (bootstrap account, tailnet auto-join, lockdown).

## What it is / isn't

- **Is:** a headless `e2-standard-4` (4 vCPU / 16 GB) that clones this repo and
  runs `claude` against open issues via the `issue-driven-development` skill,
  pushing branches and opening PRs with a scoped GitHub PAT.
- **Isn't:** a build box. Heavy builds and the KVM test suite **offload to
  `gcp-builder`** (no nested virt here). Not a service host: no
  Vaultwarden/LGTM/nginx, no backups.

## Security posture (how it differs from gcp-builder)

- **Narrow sudo.** `security.sudo.wheelNeedsPassword` stays at its default
  (`true`) — it is **not** set to `false`. A box running autonomous Claude Code
  sessions must not grant a session trivial root. It does not deploy, so it
  never needs deploy-rs activation sudo. Enforced by the
  `gcp-agent keeps wheelNeedsPassword (narrow sudo)` invariant
  (`flake/checks.nix`). **Consequence:** `deploy '.#gcp-agent'` will not
  auto-activate as `user` (no passwordless sudo). Ongoing config changes are
  applied by reprovisioning (disposable model) or by running the activation
  step manually; the registry keeps `deploy.sshUser` only for tailnet/deploy
  metadata parity.
- **No `&user` personal age key on the host.** That key can decrypt every
  `&user` secret on every host; placing it on an autonomous box is too much
  blast radius. Instead this host's `claude` credentials and GitHub PAT are
  **host** sops secrets — encrypted to the `gcp-agent` host key, decrypted at
  activation by the host SSH key, and dropped into `user`'s home. The Home
  Manager `agent` role therefore sets `userSecrets.enable = false`
  (`home/users/user/agent.nix`).
- **Tailnet-only, key-only SSH** (`tag:agent`, `acceptFrom.workstation = [22]`):
  reachable over Tailscale from `main`/`mac` only; public TCP/22 stays denied by
  the network-wide `deny_public_ssh` rule. The ACL rule
  `tag:workstation -> tag:agent:22` is derived automatically by `lib/acl.nix`
  from the registry entry — no manual ACL edit.

## Secrets

Pre-generated host identity lives under `secrets/` (encrypted to `&user` +
`&gcp_agent_host`), same bootstrap pattern as `homeserver-gcp`/`mac`:

- `ssh_host_ed25519_key.enc` / `.pub.enc` — the host SSH key, installed into the
  target root during provisioning so sops can decrypt on first boot.
- `claude-credentials.enc` — this host's own `claude` login (binary sops;
  `.json` is not allowed under `hosts/*/secrets/`). Placeholder until captured
  (see provisioning step 7). Decrypts to `/home/user/.claude/.credentials.json`.
- `gh-hosts.yaml` — `gh` config carrying the scoped GitHub PAT. Placeholder
  until captured. Decrypts to `/home/user/.config/gh/hosts.yml`; git HTTPS is
  routed through `gh auth git-credential` (set in `agent.nix`) so `git push`
  and `gh` API share the one token.

Edit any of these with `sops <file>`. See the inventory + rotation notes in
[`docs/security.md`](../../docs/security.md).

## Provisioning (operator-only, one time)

Mechanics mirror the builder; read its runbook for the shared steps. The
differences for the agent are the **`tag:agent`** auth key and the **secret
capture** in steps 7–8.

1. **tfvars** — ensure `infra/terraform.tfvars` has `gcp_project` and
   `bootstrap_ssh_public_key` (shared with the homeserver/builder flow).

2. **Mint a Tailscale auth key** — admin → Keys → Generate: **reusable**,
   **non-ephemeral**, **pre-approved**, **tagged `tag:agent`**. Stage it:

   ```bash
   umask 077
   mkdir -p /tmp/agent-extra/var/lib
   printf 'tskey-auth-XXXX' > /tmp/agent-extra/var/lib/tailscale-authkey
   ```

   Also stage the pre-generated host SSH key so sops works on first boot:

   ```bash
   mkdir -p /tmp/agent-extra/etc/ssh
   sops -d hosts/gcp-agent/secrets/ssh_host_ed25519_key.enc \
     > /tmp/agent-extra/etc/ssh/ssh_host_ed25519_key
   sops -d hosts/gcp-agent/secrets/ssh_host_ed25519_key.pub.enc \
     > /tmp/agent-extra/etc/ssh/ssh_host_ed25519_key.pub
   chmod 600 /tmp/agent-extra/etc/ssh/ssh_host_ed25519_key
   ```

3. **Create the VM** — `cd infra && tofu plan && tofu apply`. Review the plan
   (the disk-type / `desired_status` pins keep the live homeserver/builder from
   being replaced).

4. **Temporary SSH path** — open a scoped, higher-priority hole for install:

   ```bash
   gcloud compute firewall-rules create gcp-agent-provision-ssh \
     --network=default --direction=INGRESS --action=ALLOW \
     --rules=tcp:22 --target-tags=gcp-agent --priority=400 \
     --source-ranges="$(curl -fsS ifconfig.me)/32"
   ```

5. **Install NixOS** — over the bootstrap account, placing the auth key and host
   key into the installed root (ssh-agent auth; don't pass a passphrased `-i`):

   ```bash
   IP=$(cd infra && tofu output -raw agent_external_ip)
   nix run github:nix-community/nixos-anywhere -- --flake .#gcp-agent \
     --target-host "bootstrap@$IP" \
     --extra-files /tmp/agent-extra \
     --ssh-option StrictHostKeyChecking=accept-new
   ```

   On reboot it reads `/var/lib/tailscale-authkey`, joins as `tag:agent`, and
   sops decrypts with the installed `/etc/ssh/ssh_host_ed25519_key`.

6. **Verify + lock down** — confirm tailnet join, remove bootstrap metadata,
   scrub the staged keys, remove the temporary hole (same loop as the builder):

   ```bash
   AGENT=$(cd infra && tofu output -raw agent_name)
   ZONE=$(cd infra && tofu output -raw instance_zone)
   tailscale status | grep gcp-agent
   for k in bootstrap-ssh-public-key startup-script; do
     gcloud compute instances remove-metadata "$AGENT" --zone "$ZONE" --keys "$k" || true
   done
   shred -u /tmp/agent-extra/var/lib/tailscale-authkey \
            /tmp/agent-extra/etc/ssh/ssh_host_ed25519_key
   gcloud compute firewall-rules delete gcp-agent-provision-ssh --quiet
   ```

7. **Capture the `claude` login** — SSH in over Tailscale, run `claude` once to
   complete an interactive login on this host, then capture its credentials into
   sops from your workstation:

   ```bash
   ssh user@gcp-agent.tail90fc7a.ts.net   # then: run `claude`, log in, exit
   # back on your workstation, pull the freshly written creds into sops
   # (binary, so the JSON bytes are preserved verbatim):
   ssh user@gcp-agent.tail90fc7a.ts.net 'cat ~/.claude/.credentials.json' \
     | sops -e --input-type binary --output-type binary \
         --filename-override hosts/gcp-agent/secrets/claude-credentials.enc /dev/stdin \
     > hosts/gcp-agent/secrets/claude-credentials.enc
   ```

If `claude -p 'say ok' --model sonnet --dangerously-skip-permissions` fails
with `401 Invalid authentication credentials`, refresh this secret from a
currently working login and reprovision or manually activate the host. The
OAuth access token in `.credentials.json` is time-bound, and a stale encrypted
secret can decrypt cleanly while still failing at runtime. A reboot or
activation re-materializes `/home/user/.claude/.credentials.json` from
`hosts/gcp-agent/secrets/claude-credentials.enc`, so updating only the live
home file is temporary; refresh the encrypted secret too.

8. **Provision the scoped GitHub PAT** — mint a fine-grained PAT limited to this
   repo with **Contents, Issues, Pull requests: read/write**. Put it in the
   `gh` hosts file via sops (`sops hosts/gcp-agent/secrets/gh-hosts.yaml`),
   structured as `gh` expects:

   ```yaml
   github.com:
     oauth_token: github_pat_XXXX
     git_protocol: https
     user: FilipNowakowicz
   ```

   Redeploy/reprovision so the new secrets land, then verify on the host:
   `gh auth status` succeeds, and a throwaway branch can be pushed and a PR
   opened + closed.

## Lifecycle (on-demand: start + idle auto-shutdown)

Like `gcp-builder`, `gcp-agent` is normally **powered off**; it is started for a
session and powers itself back off when idle.

### How you start a session

`scripts/agent-session.sh` is the start side (the agent analog of
`validate.sh`'s build-focused `ensure_builder`, kept separate because its job is
to open a session, not offload a build):

```bash
scripts/agent-session.sh                  # start, wait for SSH over Tailscale, open a shell
scripts/agent-session.sh --wait-only      # start + confirm reachability, then return
scripts/agent-session.sh --preflight-only # start + confirm SSH, gh, and claude auth
scripts/agent-session.sh --issues <n|--label x>...
                                          # start, wait, run the issue loop (works on a fresh host)
scripts/agent-session.sh -- <cmd...>      # start, wait, run <cmd...> on the host
```

It `gcloud`-starts the VM (no-op if already running), waits for SSH at
`gcp-agent.tail90fc7a.ts.net`, then opens an interactive shell or runs the
passed command. If `gcloud` is not on `PATH` but `nix` is available, it falls
back to `nix shell nixpkgs#google-cloud-sdk -c gcloud` so a normal checkout can
start the VM without manually entering a dev shell first. Knobs: `AGENT_NAME`,
`AGENT_ZONE`, `AGENT_FQDN`, `SSH_USER`. **Prerequisite:** Google Cloud SDK
credentials are authenticated with the agent's project active, and tailnet
access as `tag:workstation`.

### Idle auto-shutdown

`agent-idle-shutdown.timer` (in `default.nix`) checks every 5 min (first check
15 min after boot) and powers the box off after **60 min** of idle. "Idle" is
deliberately more conservative than the builder's "no SSH connection", because a
Claude Code session may run **detached** (no SSH) for a long time or hold an SSH
connection open while doing nothing. The box counts as **active** while ANY of:

- an established inbound SSH connection (`ss` on port 22), or
- a running Claude Code process (`pgrep` for the `claude` wrapper /
  `claude-code` node process), or
- the orchestration entrypoint process (`agent-run-issue`) is running, or
- the orchestration session lock `/run/agent/session.lock` exists (the
  entrypoint holds it for the whole run, covering `claude`-free gaps such as an
  offloaded build).

The 60-min window (vs the builder's 20) reflects long-running, bursty sessions.
The stamp lives in `/run`, so a fresh boot gets a full grace window before the
first check.

## Issue-loop orchestration

`scripts/agent-run-issue.sh` is the repeatable entrypoint. Given a target issue
number (or a `--label` filter) it drives the `issue-driven-development` skill
from a cold, up-to-date clone to a pushed PR, then returns and lets the
idle-shutdown timer power the box off. **v1 is attended**: it opens PRs but
never merges — you review and merge yourself.

From your workstation (cold start → run → leave idle):

```bash
# one issue
scripts/agent-session.sh --issues 169
# every open issue with a label (sequential, one PR each)
scripts/agent-session.sh --issues --label architecture-review
```

`--issues` ships the **workstation's** copy of `agent-run-issue.sh` to the host
(temp file + exec; the temp name keeps the idle timer's
`pgrep -f agent-run-issue` activity check matching), so it works on a fresh
host where no repo clone exists yet — the on-host
`nix/scripts/agent-run-issue.sh` path only exists once a clone does. Directly
on the host after `scripts/agent-session.sh` opens a shell, an existing clone's
copy works too: `scripts/agent-run-issue.sh 169 170`.

On a fresh or just-reprovisioned host `$AGENT_REPO_DIR` does not exist yet —
the entrypoint bootstraps it itself (`git clone` over HTTPS, authenticated via
the same `gh auth git-credential` PAT helper) before doing anything else. No
manual clone step is required. If `$AGENT_REPO_DIR` exists but is not a git
clone, it fails fast rather than touching the directory.

What it does per issue:

1. Bootstrap: clone `$AGENT_REPO_DIR` from `$REPO_URL` if it doesn't exist yet
   (first run / after reprovisioning); otherwise reuse the existing clone.
2. Before shipping the runner, `scripts/agent-session.sh --issues ...`
   preflights `gh auth status` and a cheap `claude -p "say ok"` on the host.
   This fails fast for expired OAuth or PAT problems before burning queued
   issue sessions.
3. `git fetch` + `reset --hard origin/main` (criterion: clone up to date with `main`).
4. Runs `claude -p` headless, instructing it to follow the
   `issue-driven-development` skill: branch off `main`, smallest durable fix,
   validate with the `nix-verification-loop` skill, push, open a PR linking the
   issue (`Closes` only if fully satisfied, else `Refs`), never merge, never
   push to `main`.
5. Push + PR creation use the host's scoped GitHub PAT via `gh` and the
   `gh auth git-credential` helper (`home/users/user/agent.nix`).

Knobs: `AGENT_REPO_DIR` (default `$HOME/nix`), `BASE_BRANCH` (default `main`),
`REPO_URL` (default this repo's HTTPS URL, used only for the initial clone).
It fails fast if `gh auth status` is not authenticated (PAT not yet provisioned)
rather than burning a session.

## Failure handling

- **`merge-gate` fails on the produced PR.** Expected and safe — nothing is
  merged. Re-run the same issue to let a fresh session iterate on the existing
  branch, or fix it yourself from your workstation. To re-run:
  `scripts/agent-session.sh -- nix/scripts/agent-run-issue.sh <issue>` again; the
  entrypoint re-syncs `main` and lets `claude` continue. (Claude opens/updates a
  branch; if a stale branch exists, prune it on the host with
  `git push origin --delete <branch>` or let the new run open a fresh one.)
- **A session exits non-zero or stalls.** The entrypoint logs it and moves on
  (when several issues were passed); the run returns a non-zero exit overall.
  The VM still goes idle and powers off after the window — a wedged session does
  not pin the box on indefinitely beyond the 60-min idle clock once `claude` has
  exited.
- **Telling from `main` that a session needs attention.** There is no custom
  dashboard (a non-goal); use `gh` from your workstation:
  - `gh pr list --state open` — what got opened.
  - `gh pr checks <n>` — whether `merge-gate` passed on a given PR.
  - `gh run list --branch <branch>` — CI runs for a branch.
  - VM power: `gcloud compute instances describe gcp-agent --zone europe-west2-a --format='value(status)'`
    (`TERMINATED` = idle/off as expected; `RUNNING` long after a session implies a
    still-active or stuck run — SSH in and check `pgrep -af agent-run-issue`).

## Remote-builder offload (gcp-builder)

Like `main`, this host can offload heavy `scripts/validate.sh` tiers
(`host`/`hosts`/`heavy`/`profile-test(s)`/`smoke-*`) to the on-demand
`gcp-builder` VM via `ensure_builder` — see
[`docs/remote-builder.md`](../../docs/remote-builder.md) for the pattern and
[`hosts/gcp-builder/CLAUDE.md`](../gcp-builder/CLAUDE.md#build-key-rotation) for
the shared mechanics. `gcp-agent` carries its **own** dedicated build key
(`./nix-remote-build.nix`, `./secrets/gcp_builder_build_key.enc`) —
independently revocable from `main`'s, so a compromised agent session cannot
reuse `main`'s root-equivalent credential to `gcp-builder` (#304).

Two differences from `main`:

- `gcloud` is not part of this host's base packages; `scripts/validate.sh`
  falls back to `nix shell nixpkgs#google-cloud-sdk -c gcloud` when `gcloud` is
  not on `PATH`.
- The unprivileged readiness probe (the `ssh user@gcp-builder...` check before
  passing `--builders`) authenticates with `gcp_builder_build_key` itself
  (`owner = "user"` in `nix-remote-build.nix`) rather than a personal SSH key,
  since this host deliberately carries no `&user` personal age key.

### Operator follow-ups to make offload live

The Nix-side wiring above lands declaratively, but these out-of-band steps are
required before `agent-run-issue.sh` sessions actually offload to
`gcp-builder`. Until they're done, `ensure_builder` logs why and falls back to
a local build — safe, just slower:

1. **Redeploy/reprovision `gcp-builder`** so its `authorizedKeys` picks up the
   new `nix-remote-build-gcp-agent-to-gcp-builder` public key
   (`hosts/gcp-builder/default.nix`).
2. **Apply the Tailscale ACL** (`scripts/apply-tailscale-acl.sh`) so the new
   `tag:agent -> tag:builder:22` rule (generated from `lib/hosts.nix`'s
   `gcp-builder.tailscale.acceptFrom.agent`) takes effect on the live tailnet.
3. **Redeploy/reprovision `gcp-agent`** itself so it picks up the new sops
   secret (`gcp_builder_build_key`) and `nix-remote-build.nix` config — narrow
   sudo means no deploy-rs auto-activation (see the top-level CLAUDE.md).
4. **Grant `gcp-agent`'s GCE service account permission to start/stop/describe
   `gcp-builder`.** Neither `infra/agent.tf` nor `infra/builder.tf` currently
   attach a `service_account` block, so `gcp-agent` has no GCP credentials for
   `gcloud` at all. Without this, `ensure_builder`'s
   `gcloud compute instances start gcp-builder` step fails with an auth error
   and offload falls back to local — logged, not fatal, but the "offload heavy
   builds to `gcp-builder` by default" acceptance criterion won't hold until a
   service account with `compute.instances.{start,stop,get}` on `gcp-builder`
   is attached to the `gcp-agent` instance and the IAM binding is applied
   (`tofu apply` in `infra/`).

## Validation

```bash
bash scripts/validate.sh host gcp-agent   # build the closure
bash scripts/validate.sh flake-eval        # nix flake check --no-build
bash scripts/validate.sh light             # invariants + sops-bootstrap + registry parity
```

## Gotchas

- **Reprovisioning keeps the SSH host key** (it is pre-generated and re-installed
  from sops), so `known_hosts` on `main`/`mac` stays valid across reinstalls —
  unlike the builder, whose key is regenerated each install.
- **No console password** — recover a wedged agent by reprovisioning, not serial
  console (disposable model).
- **Placeholder secrets fail at runtime, not build** — until steps 7–8 are done,
  the closure still builds and evaluates (the encrypted files exist), but
  `claude`/`gh` on the host will not authenticate. That is expected pre-capture.
