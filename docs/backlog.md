# Backlog

Deferred work that is intentionally not in `docs/goals.md`.

## Cross-System Check Strategy

Status: postponed until the first non-`x86_64-linux` host is planned or added.

Why postponed:

- The current fleet appears to be `x86_64-linux` only.
- The immediate structural change is per-host `system` metadata in `lib/hosts.nix`.
- Broadening checks now would add CI and tooling complexity before there is a concrete second architecture to validate.

Depends on:

- Per-host system declarations for hosts, so architecture selection comes from host metadata instead of a single global flake default.

Scope when revisited:

- `nix flake check --all-systems`
- `aarch64-linux` evaluation readiness
- Gating or refactoring x86-specific VM and test tooling

## Deferred Strategic Goals

### Full Service Composition DSL

Status: deferred.

This should wait until there are enough real services to reveal the right shape. A DSL that emits Nginx locations, firewall rules, backup paths, hardening, and Alloy scrape config could be useful, but premature abstraction would hide important security and exposure decisions.

Trigger to revisit:

- At least two or three additional services repeat the same cross-cutting pattern and the manual edits become error-prone.

### `aarch64-linux` Support

Status: deferred.

The current active fleet is `x86_64-linux`. Adding broad cross-system checks now would increase evaluation and CI complexity without a real ARM host to validate.

Trigger to revisit:

- A real ARM host is planned or added to `lib/hosts.nix`.

### AppArmor Or Broader MAC Policy

Status: deferred.

Mandatory access control can be valuable, but it has a high tuning and maintenance cost. The current security model gets more immediate value from systemd sandboxing, service exposure discipline, and restore verification.

Trigger to revisit:

- A specific threat model or service requires confinement beyond systemd hardening.

### Full Flake-Parts Modular Decomposition

Status: rejected for now.

The repo already uses flake-parts where it helps. Splitting the flake further would mostly be aesthetic at the current size unless a concrete maintenance problem appears.

Trigger to revisit:

- Flake outputs become difficult to understand or new contributors routinely touch unrelated output definitions by mistake.

### config.specialisation

Status: deferred.

Lets you define alternate boot entries from the same config — e.g. a gaming specialisation with Steam, gamemode, and a different GPU profile, or a minimal one without the desktop. Completely absent from your config and genuinely useful for a desktop machine.

## Homeserver Parked Ideas

Status: not active priorities right now; revisit if manual deploys or secret hygiene become real pain points.

### Automated Deploy Pipeline

Why parked:

- Manual deploy flow is currently acceptable.
- The repo already has validation and smoke-test entrypoints without requiring GitHub Actions automation.
- Runner placement and KVM split still add operational complexity.

Scope when revisited:

- Self-hosted GitHub Actions runner as a NixOS service
- Validation and smoke-test gating before deploy
- Ordered rollout for `homeserver-gcp` and then `main`

### Secret Rotation Ritual

Why parked:

- Rotation is useful but largely procedural and only partly automatable.
- The current setup does not justify prioritizing this over active service and auth work.

Scope when revisited:

- Secret inventory with owner, trigger, and command path
- Rotation checklist through `sops` and deploy
- Optional Grafana visibility for secret age metadata
