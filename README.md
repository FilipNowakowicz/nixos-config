# NixOS & Home Manager Flake

A single, reproducible NixOS & Home Manager flake designed as a scalable, long-term setup.
The repository separates hardware, host identity, system profiles, and user configuration to support multiple machines.

---

## Overview

- **Reproducible & Declarative**: NixOS defines the entire system state, services, and hardware. Home Manager manages the user environment and dotfiles.
- **Multi-Host Ready**: Built from reusable profiles for a primary workstation (`main`), a GCP homeserver (`homeserver-gcp`), and Home Manager profiles. The host registry defines the target architecture (`system`) per host; the current fleet is `x86_64-linux`.
- **Secrets Management**: Handled by [sops-nix](https://github.com/Mic92/sops-nix) with age encryption, with secrets decrypted at boot by the host itself.
- **Impermanent Root**: `main` uses an ephemeral root filesystem with [impermanence](https://github.com/nix-community/impermanence). System state is reset on boot, with persistent data explicitly stored on `/persist`.
- **Declarative Disks**: Disk layouts for real hosts are managed declaratively with [disko](https://github.com/nix-community/disko).
- **Runtime Theming**: A runtime-swappable color system allows changing themes without a full NixOS rebuild.

---

## Documentation Map

- [Architecture](docs/architecture.md) - layer boundaries, global imports, and host registry rules.
- [Operations](docs/operations.md) - deployment, validation, and formatting commands.
- [Security Model](docs/security.md) - sops recipients, initrd SSH, Tailscale exposure, USBGuard, hardening, and backups.
- [Neovim](docs/neovim.md) - editor architecture, module layout, and current follow-up work.
- [Backlog](docs/backlog.md) - deferred and remaining infrastructure work.

---

## Support Policy

This is personal infrastructure maintained to a publishable quality bar, not a reusable NixOS distribution.

Supported contracts:

- Flake evaluation, formatting, lightweight checks, library tests, invariants, and CI planner tests should work from a clean clone.
- `x86_64-linux` is the only supported system today.
- `main` is the active workstation target and is hardware-bound to the owner's machine.
- `homeserver-gcp` is the active GCP homeserver target.
- Secrets are managed with sops-nix. Encrypted files are committed; private keys and live service credentials are not.
- Destructive install/reinstall commands are operator-only and must not be run without reviewing target disks.

Unsupported or best-effort:

- Reusing the host configs on arbitrary hardware without editing host registry, disk layouts, secrets, and hardware configs.

## What Works Without Secrets Or Hardware

Expected to work from a clean clone:

```bash
bash scripts/validate.sh flake-eval
bash scripts/validate.sh docs
bash scripts/validate.sh light
bash scripts/test-ci-plan.sh
bash scripts/doctor.sh
bash scripts/check-secrets-directory.sh --working-tree
nix fmt -- --fail-on-change
nix build '.#packages.x86_64-linux.inventory-data'
nix build '.#packages.x86_64-linux.tailscale-acl'
```

Requires extra local capability:

- NixOS smoke/profile tests require KVM.
- `main` switch requires the owner's workstation hardware and secrets.
- `homeserver-gcp` deploy requires GCP credentials, Tailscale auth key, and sops access.
- R2 binary cache publishing requires CI secrets.

## Destructive Operations

Disk provisioning and reinstall workflows are destructive. Review the target device before running `disko` or `nixos-anywhere`. The `main` disk layout targets the stable NVMe by-id path in `hosts/main/disko.nix`; do not replace it with kernel-order names like `/dev/nvme0n1` unless the disk identity changes.

---

## Secure Boot & Encryption for `main`

The `main` host uses a secure, encrypted systemd-boot setup:

- **Bootloader**: [Lanzaboote](https://github.com/nix-community/lanzaboote) manages Secure Boot, signing a unified kernel image.
- **Disk Encryption**: LUKS encrypts the Btrfs root disk.
- **Btrfs Layout**: `disko` creates `@root`, `@home`, `@nix`, and `@persist`; `/nix` and `/persist` are marked `neededForBoot`.
- **Compression & Local Snapshots**: the primary Btrfs subvolumes mount with `compress=zstd`, and `btrbk-local.timer` keeps daily local snapshots of `@home` and `@persist` for same-disk recovery.
- **Ephemeral Root**: initrd systemd rolls `@root` back to the empty `@root-blank` snapshot on every boot, moves the previous root to top-level `old_roots/`, and keeps old roots for 30 days.
- **Persistent State**: impermanence bind mounts machine identity, SSH host keys, service state, Wi-Fi profiles, Mullvad, Tailscale, Bluetooth, USBGuard, Secure Boot PKI, logs, and NixOS state from `/persist`.
- **Filesystem Maintenance**: Btrfs scrub is enabled monthly for `/`; fstrim runs via the standard timer.
- **TPM Unlocking**: The system's TPM 2.0 is used to automatically unlock the LUKS-encrypted disk on boot.
- **Hardware Pass-through**: IOMMU is enabled (`intel_iommu=on iommu=force`) for potential VM GPU pass-through.
- **Graphics Drivers**: The configuration pins `AQ_DRM_DEVICES` to a stable udev symlink for the Intel iGPU to keep multi-GPU / monitor behavior predictable.
- **Initrd SSH Recovery**: In case of TPM failure, an initrd SSH server (port 2222) is available for remote LUKS unlocking using the dedicated recovery key stored in `lib/recovery-pubkeys.nix`.
  - **Recovery Procedure**:
    1. Retrieve the `id_ed25519_recovery` private key from offline storage.
    2. Connect the host via wired Ethernet (WiFi is unavailable in stage 1).
    3. `ssh -i /path/to/id_ed25519_recovery -p 2222 root@<host-ip>`
    4. Enter the LUKS passphrase when prompted to unlock the disk.
    5. The system will continue booting into stage 2.
  - **Rotation Expectation**: Rotate recovery access by updating `lib/recovery-pubkeys.nix` and redeploying `main`; keep the private key offline and separate from day-to-day SSH credentials.

---

## Features

- **Runtime Theming**: A runtime-swappable color system allows changing themes without a full NixOS rebuild.
- **Packaged Control Center**: The desktop control center now lives in `packages/control-center` as a first-class flake package/app instead of a loose Home Manager script, so its GTK4 code and runtime wrapper are versioned together.
- **USB Device Control**: USBGuard enabled on `main` with a strict deny-default policy and a curated allowlist for trusted internal/peripheral devices.
- **Workstation Backups**: `main` backs up user-critical state and persisted service identity to Backblaze B2 with Restic, including Codex/Claude state, Wi-Fi profiles, Mullvad, Tailscale, Bluetooth, fingerprint, USBGuard, Secure Boot PKI, machine-id, and SSH host identity.
- **Recovery Boundary**: local Btrfs snapshots are for short-term rollback on the same disk; Restic/B2 remains the off-site recovery path.
- **Scoped Agent Maintenance Sudo**: `main` keeps normal `wheel` sudo passworded, but allows a narrow set of passwordless maintenance commands for interactive agent sessions: local snapshot start/status, Restic start/status, boot cleanup, selected EFI entry deletion, Nix GC, and switching this flake path.
- **Tailscale ACLs as Nix**: Security rules and tag owners are generated declaratively from the host registry, providing a single source of truth for network access control.
- **Generated Inventory Export**: `packages/inventory-data.nix` exports host inventory as JSON for the homepage site.
- **Systemd Hardening**: A custom DSL (`services.hardened`) applies a high-security sandbox baseline to critical services (Vaultwarden, Nginx, Syncthing).
- **Intrusion Prevention**: Fail2ban integrated into the security profile with automated E2E testing.
- **Idle Policy (desktop)**: Hypridle locks at 10 minutes of inactivity and suspends at 15 minutes.
- **Centralized Keys**: Normal SSH public keys live in `lib/pubkeys.nix`; initrd recovery-only keys live in `lib/recovery-pubkeys.nix`.
- **Shared SSH Agent**: Home Manager runs a single user `ssh-agent` service; shells use one shared socket, so loaded keys are reused across terminals.

---

## Repository Structure

```
.
├── flake.nix                          # Flake entry point
├── .sops.yaml                         # SOPS configuration for secret management
├── docs/
│   ├── architecture.md                 # Structural rules and module boundaries
│   ├── operations.md                   # Deployment and validation runbook
│   ├── security.md                     # Secrets, exposure, and hardening model
│   └── backlog.md                      # Deferred work
├── lib/
│   ├── hosts.nix                      # Host registry (typed schema; single source of truth for all hosts)
│   ├── generators.nix                 # Typed Alloy HCL generators
│   ├── dashboards.nix                 # Typed Grafana dashboard builders
│   ├── invariants.nix                 # Configuration invariant check builders
│   ├── cve-checks.nix                 # CVE scanning check builders
│   ├── pubkeys.nix                    # Standard SSH public keys
│   ├── recovery-pubkeys.nix           # Initrd recovery-only SSH public keys
│   ├── syncthing.nix                  # Shared Syncthing device/folder registry
│   └── acl.nix                        # Declarative Tailscale ACL generator
├── packages/
│   ├── control-center/                # Packaged GTK4 control center app and wrapper
│   └── inventory-data.nix             # Host inventory export as JSON
├── hosts/
│   ├── main/                          # Primary workstation
│   │   ├── CLAUDE.md                  # Host-local runbook and gotchas
│   │   ├── default.nix
│   │   ├── disko.nix
│   │   ├── impermanence.nix
│   │   └── hardware-configuration.nix
│   ├── homeserver-gcp/                # GCP homeserver (Vaultwarden, LGTM, Nginx)
│   │   ├── default.nix
│   │   └── secrets/
│   └── installer/                     # Minimal NixOS ISO for fresh installs
│       └── default.nix
├── scripts/
│   ├── ci-plan.sh                     # CI path filtering and job matrix planner
│   ├── closure-diff.sh                # Closure size diff helper for PR comments
│   ├── validate.sh                    # Local/CI validation entry point
│   ├── check-doc-links.sh             # Markdown link checker used by CI
│   ├── doctor.sh                      # Clean-clone validation bundle
│   └── deploy-gcp.sh                  # GCP homeserver deploy wrapper
├── modules/
│   └── nixos/
│       ├── hardware/                  # Hardware-specific modules (NVIDIA PRIME)
│       ├── profiles/
│       │   ├── base.nix               # Base system settings (Nix, locale)
│       │   ├── desktop.nix            # Desktop environment (Hyprland, PipeWire)
│       │   ├── security.nix           # Security hardening (Firewall, SSH)
│       │   ├── observability/         # LGTM observability stack (Grafana, Loki, Tempo, Mimir)
│       │   ├── observability-client.nix
│       │   ├── backup.nix
│       │   ├── impermanence-base.nix
│       │   ├── machine-common.nix
│       │   ├── machine-dev.nix
│       │   ├── microvm-guest.nix
│       │   ├── sops-base.nix
│       │   └── user.nix               # User account and home-manager base
│       └── services/
│           ├── hardened.nix           # Systemd service hardening DSL (sandbox extraction)
│           └── systemd-failure-notify.nix
└── home/
    ├── profiles/                      # User-level profiles (home-manager)
    │   ├── base.nix
    │   ├── desktop.nix
    │   └── workstation.nix            # Workstation-specific packages (TeX, Anki, VS Code)
    ├── theme/
    │   ├── active.nix                 # Active theme pointer
    │   ├── module.nix                 # Home Manager theme module
    │   ├── themes/
    │   └── wallpapers/
    ├── users/
    │   └── user/
    │       ├── home.nix
    │       ├── server.nix
    │       └── wsl.nix                # Portable HM for Windows (WSL)
    └── files/                         # Static dotfiles and scripts
        ├── kitty/
        ├── nvim/
        ├── scripts/                   # Utility scripts; control-center moved to packages/control-center
        └── waybar/
```

---

## Adding A New Host

1. Add an entry to `lib/hosts.nix` with role and Home Manager metadata.
2. Create `hosts/<name>/default.nix` with the appropriate host profiles.
3. If the host has a checked-in `hardware-configuration.nix`, add a short header documenting its regeneration policy and `Last reviewed: YYYY-MM-DD`.
4. Add the host's sops recipient and secrets manually.

---

## Hosts

Host lifecycle status for NixOS host configurations is owned by
`lib/hosts.nix`; this table documents that registry. `installer` is a utility
ISO outside the host registry.

| Host             | Status  | Description                                                                        |
| ---------------- | ------- | ---------------------------------------------------------------------------------- |
| `main`           | Active  | Primary workstation, running a full desktop environment with NVIDIA PRIME support. |
| `homeserver-gcp` | Active  | GCP homeserver running Vaultwarden, Syncthing, LGTM, Nginx, and Tailscale.         |
| `installer`      | Utility | Minimal ISO configuration used to bootstrap new installations.                     |

### Deployment

| Host             | Command                                  | Notes                                        |
| ---------------- | ---------------------------------------- | -------------------------------------------- |
| `main`           | `nh os switch --hostname main .`         | Active impermanent workstation rebuild.      |
| `homeserver-gcp` | `deploy '.#homeserver-gcp'`              | GCP homeserver; see `scripts/deploy-gcp.sh`. |
| `user@wsl`       | `home-manager switch --flake .#user@wsl` | Portable Home Manager for WSL.               |

---

## Theming

The color system is designed to be **runtime-swappable**. Most GUI applications (Waybar, Kitty, Mako, Hyprland) source colors generated by Nix from a central theme file. This logic is handled by the `home/theme/module.nix` Home Manager module, which provides a `themes.active` option to set the system-wide theme.

A `theme-switch` script is available in the shell to list and apply themes. It uses the `NIX_REPO` environment variable to locate the configuration.

### How to Switch Themes

1.  **List available themes**:
    ```bash
    theme-switch
    ```
2.  **Switch to a new theme**:
    ```bash
    theme-switch <theme-name>
    ```
    This command updates `home/theme/active.nix`, symlinks the new theme's pre-generated configs into place (Kitty, Hyprland, Hyprlock, Waybar, Mako, wallpaper), and reloads running applications — no rebuild required.

### How to Add a New Theme

1.  **Create a new theme file** in `home/theme/themes/`, following the structure of the existing themes (e.g., `nighthawks.nix`). A theme requires a `name`, `colors` set, and a path to a `wallpaper`.
2.  **The new theme will be available** automatically via the `theme-switch` script.

---

## Services (homeserver-gcp)

| Service           | Purpose                                                                                          | Access                                                      |
| ----------------- | ------------------------------------------------------------------------------------------------ | ----------------------------------------------------------- |
| **Tailscale**     | Zero-config VPN for secure remote access.                                                        | Connect from any Tailscale client.                          |
| **Nginx**         | Reverse proxy with automatic Tailscale TLS certs.                                                | `https://homeserver-gcp.<tailnet-name>.ts.net`              |
| **Vaultwarden**   | Self-hosted Bitwarden-compatible password manager with websocket notifications for instant sync. | `https://homeserver-gcp...` (via Nginx)                     |
| **Syncthing**     | Continuous, peer-to-peer file synchronization.                                                   | `http://localhost:8384` (via SSH tunnel)                    |
| **AdGuard Home**  | Tailnet DNS filtering and ad-blocking.                                                           | DNS on `tailscale0`; web UI on `http://<tailscale-ip>:3001` |
| **Restic/B2**     | Off-site backups to Backblaze B2.                                                                | Automated via systemd timers; see `backup.nix`.             |
| **GCE Snapshots** | Fast provider-local rollback for the boot disk.                                                  | Daily schedule managed by `infra/main.tf`.                  |

---

## Observability

`homeserver-gcp` runs the full LGTM stack. The observability stack is active and operated, including backup, host-hardening, and CVE health signals.

### Infrastructure Dashboards

The stack includes pre-configured dashboards for fleet overview and deep-dives into the `main` machine:

- **Main Machine**: Real-time monitoring of disk usage, CPU/Memory load, thermal zones, battery health, failed systemd units, and kernel error logs.
- **Fleet Overview**: Aggregated view of CPU and memory usage across all hosts, combined with centralized systemd journal logs.
- **Backup Health**: Age of the latest restic backup and weekly repository integrity check for `homeserver-gcp`.
- **CVE Scan**: Daily `vulnix` findings and affected package count after whitelist suppression.
- **Host Hardening**: Daily `lynis` hardening index, warning count, and scan freshness.

### LGTM Stack Components

| Component                   | Purpose                          | Local endpoint                       |
| --------------------------- | -------------------------------- | ------------------------------------ |
| **Grafana**                 | Dashboards and datasource UI     | `http://127.0.0.1:3000`              |
| **Loki**                    | Log storage and querying         | `http://127.0.0.1:3100`              |
| **Tempo**                   | Trace storage/query backend      | `http://127.0.0.1:3200`              |
| **Mimir**                   | Metrics storage/query backend    | `http://127.0.0.1:9009`              |
| **Prometheus**              | Scraping + remote write to Mimir | `http://127.0.0.1:9090`              |
| **Grafana Alloy**           | Journald log shipping to Loki    | local systemd service                |
| **OpenTelemetry Collector** | Trace pipeline to Tempo          | receivers on `127.0.0.1:14317/14318` |

Authenticated ingest routes on `https://homeserver-gcp.<tailnet-name>.ts.net`:

- `/obs/loki/` → Loki push API
- `/obs/mimir/` → Mimir remote_write API
- `/obs/otlp/` → OpenTelemetry Collector HTTP ingest

Implementation is in `modules/nixos/profiles/observability/`, with client-side telemetry shipping via `modules/nixos/profiles/observability-client.nix`.

Grafana is exposed to tailnet users through nginx auth proxy on `/grafana/`, with
the caller resolved through `tailscale whois` and defaulted to a Grafana `Viewer`
role unless the host-local `grafanaTailscaleRoleMap` promotes a specific login.
The local Grafana admin account remains a break-glass path over SSH port-forwarding
to `127.0.0.1:3000`; ingest credentials are still managed with `sops` secrets.

---

## Secrets (sops-nix)

Secrets are managed with [sops-nix](https://github.com/Mic92/sops-nix) and [age](https://age-encryption.org) encryption.

### How it works

- `.sops.yaml` defines rules for which age public keys can decrypt which secret files.
- Keys are grouped by name (e.g., `&user`, `&main_host`, `&homeserver_gcp_host`).
- Host keys are derived from their respective SSH host public keys using `ssh-to-age`.
- This allows a host to decrypt its own secrets automatically during activation. Impermanent hosts keep their SSH key under `/persist` so the age key remains stable across reboots.
- The user's personal age key (`user`) can decrypt all secrets.
- `homeserver-gcp` uses a pre-baked encrypted SSH host key committed in `hosts/homeserver-gcp/secrets/`; deployed once during initial GCE image bootstrap.

### Setup

1. **Generate your personal age key** (once):

   ```bash
   age-keygen -o ~/.config/sops/age/keys.txt
   ```

   Add the public key to `.sops.yaml` under the `&user` anchor.

2. **Add a host's age key** before granting it secret access:
   For SSH-host-derived identities, get the host's SSH public key, convert it to an age key, and add it to `.sops.yaml`.

   ```bash
   # On the target host, or from a pre-generated host public key
   cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age

   # On your dev machine, add the resulting age key to .sops.yaml
   # under a new anchor (e.g., &homeserver_gcp_host) and update the
   # creation_rules to give it access to its secrets file.
   ```

3. **Edit secrets:**
   ```bash
   # Edits a file, decrypting it temporarily
   sops hosts/homeserver-gcp/secrets/secrets.yaml
   ```

**Host Key Rotation**: Rotating a host's SSH key or changing its identity requires a corresponding update to `.sops.yaml` (new age key) followed by `sops updatekeys <path/to/secrets.yaml>` to re-encrypt the file for the new key. Failing to do this before deployment will result in a boot-time decryption failure.

---

## Tooling

The flake provides several `devShells` and `apps` for development and maintenance.

| Type       | Name            | Purpose                                                                              |
| ---------- | --------------- | ------------------------------------------------------------------------------------ |
| `devShell` | `default`       | Main dev shell with `deploy-rs`, `nixos-anywhere`, `sops`, `nixd`, etc.              |
| `devShell` | `security`      | Includes common security tools: `nmap`, `gobuster`, `sqlmap`, `hydra`, `john`, etc.  |
| `app`      | `doctor`        | Clean-clone checks: `nix run '.#doctor'` or `bash scripts/doctor.sh`                 |
| `app`      | `deploy-gcp`    | GCP homeserver deploy wrapper: `bash scripts/deploy-gcp.sh`                          |
| `package`  | `installer-iso` | Minimal NixOS ISO: `nix build '.#installer-iso'`                                     |
| `template` | `python`        | Python dev shell with `uv`, `ruff`, `basedpyright`: `nix flake init -t ~/nix#python` |

---

## Neovim

The current editor setup, module layout, and open follow-up work are documented
in [docs/neovim.md](docs/neovim.md).

---

## Code Quality

### Formatting

Formatting is unified behind `nix fmt` via `treefmt-nix`:

```bash
# Format Nix + shell scripts + Markdown
nix fmt

# Check formatting without modifying files
nix fmt -- --fail-on-change
```

### Git hooks

Pre-commit hooks are configured in [`pre-commit-hooks.nix`](./pre-commit-hooks.nix), and `nix develop` also installs a flake-managed `commit-msg` hook that removes `Co-authored-by:` trailers.

```bash
# Run the full hook set manually
pre-commit run --all-files
```

Included quick checks:

- `treefmt` (Unified formatting for Nix, shell, Markdown)
- `shellcheck` (shell script linting)
- `statix` (Nix lint)
- `deadnix` (dead code)
- `no-plaintext-secrets` (high-signal plaintext secret detector)

If the secret detector flags an intentional value, add a narrow path or glob to `.plaintext-secrets-allowlist` and justify it in the commit/PR.

---

## Validation

```bash
# Fast evaluation only: flake outputs and lightweight checks evaluate
bash scripts/validate.sh flake-eval

# Lightweight blocking checks used by CI
bash scripts/validate.sh light

# Build all host system closures used by CI
bash scripts/validate.sh hosts

# Build smoke tests individually
bash scripts/validate.sh smoke-homeserver-gcp

# Build all profile-specific NixOS tests
bash scripts/validate.sh profile-tests

# Build the full heavy KVM-backed suite
bash scripts/validate.sh heavy

# View CVE scanning reports for each host
bash scripts/validate.sh cve-reports
```

`nix flake check` in this repo is intentionally evaluation-oriented. The booted NixOS tests and CVE reports live under `legacyPackages` so they can stay path-gated in CI and opt-in locally.

---

## Tailscale ACLs

Tailscale security rules are managed declaratively within the flake. The `lib/acl.nix` generator processes the `lib/hosts.nix` registry to produce a `acl.hujson` compatible structure.

- **Current Policy Scope**: The ACL model is intentionally explicit. It consumes `tailscale.tag`, `tailscale.acceptFrom`, and `tailnetFQDN` where host-specific destinations are needed.
- **Registry Richness**: Other host metadata such as `role`, `ip`, and `backup.class` remains available to the rest of the flake, but does not affect ACL generation yet.
- **Generator**: `lib/acl.nix` maps tags to owners, emits explicit workstation-to-server rules, and keeps `autogroup:admin` as deliberate break-glass access.
- **Validation**: Unit tests in `tests/lib/acl.nix` verify the generated rules and output shape.
- **Drift Detection**: `.github/workflows/tailscale-acl-drift.yml` runs `scripts/check-tailscale-acl-drift.sh` against the live tailnet policy.
- **Output**: The generated ACL JSON can be inspected via:
  ```bash
  nix build '.#packages.x86_64-linux.tailscale-acl' --print-out-paths | xargs cat
  ```

---

## Continuous Integration

The repository uses GitHub Actions (`.github/workflows/nix.yml` and `flake-update.yml`) for automated validation and maintenance. The CI pipeline is designed for both correctness and performance, using path-filtering to skip expensive tests when possible.

| Job                  | Description                                                                                                                                   |
| :------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------- |
| **Flake Evaluation** | Runs `bash scripts/validate.sh flake-eval`, which keeps `nix flake check --no-build` as a fast evaluation gate for flake outputs and configs. |
| **Light Checks**     | Runs `bash scripts/validate.sh light` for deploy checks, invariants, SOPS bootstrap validation, and lightweight library tests.                |
| **Linting**          | Runs `statix` (Nix), `deadnix` (dead code), `treefmt` (formatting), `shellcheck` (shell scripts), and Markdown link checks.                   |
| **Package Builds**   | Builds repo-native package outputs used in CI, currently `nix build '.#packages.x86_64-linux.inventory-data'`.                                |
| **Host Builds**      | Matrix-builds each host closure via `bash scripts/validate.sh host <name>`.                                                                   |
| **Smoke Tests**      | Runs `bash scripts/validate.sh smoke-homeserver-gcp` in a full NixOS environment when relevant paths change.                                  |
| **Profile Tests**    | Matrix-builds each profile test via `bash scripts/validate.sh profile-test <name>`.                                                           |
| **Closure Diff**     | Automatically computes and comments the `nvd` diff of package closures on PRs.                                                                |
| **Merge Gate**       | Consolidates all required checks into a single status; required for branch protection and automated flake updates.                            |
| **Flake Update**     | Automated weekly `flake.lock` updates via GitHub Action; auto-merges if the `merge-gate` passes.                                              |

### Path Filtering & Performance

`scripts/ci-plan.sh` generates the host and test matrices for pull requests. The planner is intentionally conservative: dependency/core changes (`flake.nix`, `flake.lock`, `lib/`, CI wiring) run the full expensive suite, while role-specific changes only run the affected host closures and tests.

Examples:

- Desktop Home Manager changes build `main-ci`, but skip GCP homeserver closures.
- Server Home Manager changes build `homeserver-gcp`, but skip desktop closures.
- `flake.lock` and shared library changes run every host closure, smoke test, profile test, and closure diff.
- Docs-only changes run lint and Markdown link checks, then skip eval/build-heavy jobs.
- WSL-only changes skip expensive host jobs; eval, lint, and light checks still run.

The workflow uses a signed Cloudflare R2 binary cache. PR and merge-queue jobs substitute from that cache but do not publish to it, keeping slow full-closure uploads off the merge path. Cache publication runs after successful `push` or manual `workflow_dispatch` builds, so merged changes warm the cache for later CI runs.

<!-- > **KVM Requirement**: NixOS integration tests require KVM virtualization. While GitHub-hosted `ubuntu-latest` runners provide `/dev/kvm` for public repositories, private or self-hosted runners must have KVM support enabled to prevent silent job timeouts. -->
