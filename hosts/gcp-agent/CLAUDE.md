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
scripts/agent-session.sh              # start, wait for SSH over Tailscale, open a shell
scripts/agent-session.sh --wait-only  # start + confirm reachability, then return
scripts/agent-session.sh -- <cmd...>  # start, wait, run <cmd...> on the host (used by #169)
```

It `gcloud`-starts the VM (no-op if already running), waits for SSH at
`gcp-agent.tail90fc7a.ts.net`, then opens an interactive shell or runs the
passed command. Knobs: `AGENT_NAME`, `AGENT_ZONE`, `AGENT_FQDN`, `SSH_USER`.
**Prerequisite:** `gcloud` authenticated with the agent's project active, and
tailnet access as `tag:workstation`.

### Idle auto-shutdown

`agent-idle-shutdown.timer` (in `default.nix`) checks every 5 min (first check
15 min after boot) and powers the box off after **60 min** of idle. "Idle" is
deliberately more conservative than the builder's "no SSH connection", because a
Claude Code session may run **detached** (no SSH) for a long time or hold an SSH
connection open while doing nothing. The box counts as **active** while ANY of:

- an established inbound SSH connection (`ss` on port 22), or
- a running Claude Code process (`pgrep` for the `claude` wrapper /
  `claude-code` node process), or
- the orchestration session lock `/run/agent-session.lock` exists (the #169
  entrypoint touches it around non-`claude` work such as an offloaded build).

The 60-min window (vs the builder's 20) reflects long-running, bursty sessions.
The stamp lives in `/run`, so a fresh boot gets a full grace window before the
first check.

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
