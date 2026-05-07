# Operations

This document is the runbook for day-to-day work in this flake. Keep the
README high-level; put command-heavy procedures here.

## Canonical Sources

- `README.md` - project overview, host inventory, feature map.
- `CLAUDE.md` - agent/operator preferences and validation shortcuts.
- `docs/architecture.md` - structural rules and module boundaries.
- `docs/security.md` - secrets, network exposure, and hardening model.

## Deployment Matrix

| Target           | Status           | Command                                  | Notes                                                          |
| :--------------- | :--------------- | :--------------------------------------- | :------------------------------------------------------------- |
| `main`           | Active           | `nh os switch --hostname main .`         | Primary workstation.                                           |
| `homeserver-gcp` | Active           | `deploy '.#homeserver-gcp'`              | GCP homeserver; see `scripts/deploy-gcp.sh`.                   |
| `vm`             | Legacy Supported | `deploy '.#vm'`                          | Requires a QEMU VM created with `nix run '.#vm' -- create vm`. |
| `user@wsl`       | Active           | `home-manager switch --flake .#user@wsl` | Portable Home Manager profile for WSL.                         |

## QEMU VM

`scripts/vm.sh` and `nix run '.#vm'` are legacy-supported for hardware-style
testing: impermanence, bootloader behavior, and LUKS workflows. They are not
the `homeserver-vm` path.

```bash
nix run '.#vm' -- create vm
nix run '.#vm' -- start vm
nix run '.#vm' -- ssh vm
nix run '.#vm' -- stop vm
nix run '.#vm' -- reinstall vm
nix run '.#vm' -- destroy vm
```

QEMU VM metadata comes from `lib/hosts.nix`; entries need `sshPort` and
`diskSize` to appear in the VM registry.

## Validation

Use the narrowest check that covers the files changed.

```bash
bash scripts/validate.sh flake-eval
bash scripts/validate.sh light
bash scripts/validate.sh host main-ci
bash scripts/validate.sh host vm-ci
bash scripts/validate.sh host homeserver-gcp-ci
bash scripts/validate.sh hosts
bash scripts/validate.sh smoke-vm
bash scripts/validate.sh smoke-homeserver
bash scripts/validate.sh profile-tests
bash scripts/validate.sh heavy
bash scripts/validate.sh cve-reports
```

Rules of thumb:

- Shared flake, library, or global module changes: run `light` and affected host builds; use `hosts` when impact is broad.
- Desktop profile/Home Manager changes: build `main-ci` and `vm-ci`.
- Server profile/GCP changes: build `homeserver-gcp-ci`.
- Docs changes: run `bash scripts/validate.sh docs`; CI runs this even for docs-only PRs.
- NixOS test changes: run the relevant smoke/profile test if KVM is available.

## Formatting And Hooks

```bash
nix fmt
nix fmt -- --fail-on-change
pre-commit run --all-files
statix check .
deadnix .
```

`nix develop` installs a `commit-msg` hook in the shared git hooks directory
that removes `Co-authored-by:` trailers.
