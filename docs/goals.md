# Goals

Active improvement goals for this flake. This document tracks work that still
fits the current architecture; outdated or intentionally deferred ideas belong
in `docs/backlog.md`.

## Principles

- Prefer goals that tighten consistency around the existing design instead of
  introducing new abstraction layers prematurely.
- Treat `main` and `homeserver-gcp` differently when their storage, threat
  model, or operational constraints differ.
- Prefer explicit policy and recovery documentation over broad "hardening"
  changes that are difficult to validate.

## Completed

| Goal                         | Difficulty | Scope        |
| :--------------------------- | :--------- | :----------- |
| ✓ `nix.registry` pinning     | Easy       | Cross-system |
| ✓ `nix-index` and `comma`    | Easy       | Developer UX |
| ✓ `xdg.mimeApps`             | Easy       | Home Manager |
| ✓ Persistence coverage audit | Medium     | `main`       |

## Active Goals

| Order | Goal                             | Difficulty | Scope            | Why now                                                                                       |
| :---- | :------------------------------- | :--------- | :--------------- | :-------------------------------------------------------------------------------------------- |
| 5     | FIDO2 for auth and SSH           | Medium     | `main`           | Natural next security layer on top of TPM, fingerprint, USBGuard, and Secure Boot.            |
| 6     | LUKS2 FIDO2 unlock               | Medium     | `main`           | Strengthens disk-unlock posture and recovery options beyond TPM-only unlock.                  |
| 7     | `systemd.tmpfiles` normalization | Medium     | Cross-system     | Standardizes directory and file bootstrapping around an existing repo pattern.                |
| 8     | Custom module option docs        | Medium     | Internal modules | Improves discoverability and editor/tooling support as the module surface grows.              |
| 9     | Desktop declarativity review     | Medium     | Home Manager     | Clarifies where typed HM modules help and where raw dotfiles remain the right tradeoff.       |
| 10    | Recovery-path audit              | Hard       | `main`           | Validates that the current boot, unlock, and break-glass paths remain coherent under failure. |

## Goal Details

### 5. FIDO2 for auth and SSH

Add a hardware security key as a first-class authentication factor on `main`.

Implementation:

- Evaluate `security.pam.u2f` for `sudo` and, if appropriate, local login.
- Adopt SSH FIDO2-backed keys where they improve operator security and recovery.
- Keep recovery paths explicit so the machine is not coupled to a single token.

Acceptance:

- The workstation supports a hardware-backed auth path for privileged access.
- Recovery expectations are documented before the mechanism becomes mandatory.

### 6. LUKS2 FIDO2 unlock

Add FIDO2-backed disk unlock as a complement to the current TPM-based setup.

Implementation:

- Evaluate whether the key should be a primary unlock factor, a secondary
  factor, or a recovery path.
- Keep the initrd and break-glass story coherent with the current remote-unlock
  design.
- Document enrollment, re-enrollment, and loss scenarios.

Acceptance:

- Disk unlock no longer depends solely on TPM behavior.
- Recovery and rotation steps are clear enough to execute under stress.

### 7. `systemd.tmpfiles` normalization

Use `systemd.tmpfiles` consistently for declarative directory and file
bootstrapping.

Implementation:

- Replace remaining ad hoc setup paths where tmpfiles is the idiomatic fit.
- Keep ownership, permissions, and copy/create behavior explicit.
- Do not force tmpfiles onto cases where another NixOS module already models
  the state better.

Acceptance:

- Directory and file initialization follows one predictable pattern across the
  repo.

### 8. Custom module option docs

Improve option descriptions for repo-owned modules so tooling output becomes
more useful.

Implementation:

- Add meaningful `description`, `example`, and related metadata where currently
  sparse.
- Prioritize modules that already act like internal APIs.

Acceptance:

- `nixos-option`, editor hover, and module browsing provide enough context to
  use internal options without reading implementation first.

### 9. Desktop declarativity review

Decide intentionally where Home Manager modules help and where raw dotfiles are
still the better fit.

Implementation:

- Review Hyprland, Kitty, and adjacent desktop config that is currently managed
  as files.
- Keep raw files where theme generation, upstream syntax, or full-control needs
  make them the cleaner option.
- Move to typed HM options only where the merge behavior or validation is worth
  the loss of directness.

Acceptance:

- Desktop config management reflects deliberate tradeoffs instead of drift over
  time.

### 10. Recovery-path audit

Validate the full failure-handling story on `main`.

Implementation:

- Review TPM unlock, initrd SSH, Secure Boot state, persistence assumptions,
  backups, and scoped maintenance sudo as one system.
- Identify single points of failure and unclear operator steps.
- Turn any non-obvious recovery assumptions into short runbook notes.

Acceptance:

- The current boot and recovery design can be explained and exercised as a
  coherent system.
- Break-glass steps are explicit enough to trust during an actual incident.
