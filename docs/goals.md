# Goals

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
