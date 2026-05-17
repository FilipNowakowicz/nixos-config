# Goals

This document is the active roadmap for the flake. It focuses on work that
improves correctness, recoverability, security, or operational confidence for
the current fleet: the `main` workstation and the `homeserver-gcp` server.

It is intentionally not a catch-all idea list. Deferred or speculative work
belongs in `docs/backlog.md`, and homeserver-specific provider work belongs in
`docs/homeserver-goals.md`.

## Goal Selection Principles

Prefer goals that:

- protect data or make recovery more reliable;
- catch regressions before deployment;
- reduce hidden state and manual drift;
- make security posture more consistent and auditable;
- improve day-to-day operation without adding broad abstraction too early.

Defer goals that:

- primarily serve hypothetical future hosts;
- add abstraction before repeated real use cases exist;
- increase CI or operational complexity without a clear current failure mode;
- duplicate functionality already covered by simpler NixOS or systemd features.

## Priority Scale

| Priority | Meaning                                                                 |
| :------- | :---------------------------------------------------------------------- |
| P0       | High-value reliability or safety work that should be done first.        |
| P1       | Important hardening or operational work with clear value.               |
| P2       | Useful improvement, but not urgent or not yet justified by current use. |
| Deferred | Parked until a concrete trigger appears.                                |

## Recommended Order

| Order | Goal                                  | Priority | Difficulty | Status  |
| :---- | :------------------------------------ | :------- | :--------- | :------ |
| 1     | Home Manager user secrets             | P2       | Medium     | Planned |
| 2     | NixOS specialisations                 | P2       | Easy       | Planned |
| 3     | Profile defaults and override hygiene | P2       | Medium     | Planned |

## Goal Details

### 1. Home Manager User Secrets

Some user-scoped credentials are better owned by user services than by global
system secrets or ad hoc dotfiles. `sops-nix` can write secrets with a specific
owner, which fits selected API tokens and user-level credentials.

Implementation:

- Inventory current user-scoped secrets and classify which should move.
- Use `sops.secrets.<name>.owner` and explicit paths outside the Nix store.
- Update user services or shell integrations to read from those paths.
- Document which secrets remain system-level and why.

Acceptance:

- Selected user credentials are encrypted in the repo and materialized only at
  runtime.
- No secret material is placed in the Nix store.
- Ownership and file permissions match the consuming user service.

Critique:

- This is valuable if there are real user secrets to manage.
- Do not migrate placeholder or rarely used credentials just for consistency.

### 2. NixOS Specialisations

NixOS specialisations can provide boot-selectable variants for recovery or
debugging without permanently weakening the default configuration.

Implementation:

- Add one practical specialisation, such as a debug kernel variant or a
  Mullvad-disabled recovery profile for `main`.
- Keep the default boot entry as the normal secure configuration.
- Document when to use the specialisation and how to verify which one booted.

Acceptance:

- The specialisation appears in the boot menu.
- The variant solves a concrete recovery or debugging need.
- The normal configuration remains unchanged unless the operator selects the
  specialisation.

Critique:

- Useful, but optional. Add this only for a real recovery workflow, not because
  the feature exists.

### 3. Profile Defaults and Override Hygiene

Base profiles currently use many direct assignments. Using `mkDefault` in the
right places would make host overrides cleaner and reduce future `mkForce`
pressure.

Implementation:

- Review base and common profiles for values that are policy defaults rather
  than hard requirements.
- Convert those assignments to `lib.mkDefault`.
- Keep security-critical requirements strict where overrides should be explicit.
- Add or update tests for any behavior that must remain enforced.

Acceptance:

- Host-specific overrides can be made without unnecessary `mkForce`.
- Security and fleet invariants remain enforced.
- The distinction between defaults and requirements is visible in review.

Critique:

- This is maintenance hygiene, not a headline goal.
- Do it opportunistically while touching related profiles unless override
  friction becomes a recurring problem.

## Deferred Or Rejected For Now

### Full Service Composition DSL

Status: deferred.

This should wait until there are enough real services to reveal the right
shape. A DSL that emits Nginx locations, firewall rules, backup paths,
hardening, and Alloy scrape config could be useful, but premature abstraction
would hide important security and exposure decisions.

Trigger to revisit:

- At least two or three additional services repeat the same cross-cutting
  pattern and the manual edits become error-prone.

### `aarch64-linux` Support

Status: deferred.

The current active fleet is `x86_64-linux`. Adding broad cross-system checks now
would increase evaluation and CI complexity without a real ARM host to validate.

Trigger to revisit:

- A real ARM host is planned or added to `lib/hosts.nix`.

### AppArmor Or Broader MAC Policy

Status: deferred.

Mandatory access control can be valuable, but it has a high tuning and
maintenance cost. The current security model gets more immediate value from
systemd sandboxing, service exposure discipline, and restore verification.

Trigger to revisit:

- A specific threat model or service requires confinement beyond systemd
  hardening.

### Full Flake-Parts Modular Decomposition

Status: rejected for now.

The repo already uses flake-parts where it helps. Splitting the flake further
would mostly be aesthetic at the current size unless a concrete maintenance
problem appears.

Trigger to revisit:

- Flake outputs become difficult to understand or new contributors routinely
  touch unrelated output definitions by mistake.
