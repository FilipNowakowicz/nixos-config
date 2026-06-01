# NixOS Flake Configuration

Personal NixOS flake for an endgame, reproducible setup.
Prefer clean, idiomatic Nix over quick fixes. Suggest better
approaches proactively. Explain why, not just what.

For repository overview and structure see [`README.md`](README.md).
For deeper context see [`docs/architecture.md`](docs/architecture.md),
[`docs/operations.md`](docs/operations.md), and
[`docs/security.md`](docs/security.md). Host-local runbooks live
under each host: [`hosts/main/CLAUDE.md`](hosts/main/CLAUDE.md),
[`hosts/mac/CLAUDE.md`](hosts/mac/CLAUDE.md),
[`hosts/homeserver-gcp/CLAUDE.md`](hosts/homeserver-gcp/CLAUDE.md),
[`hosts/gcp-builder/CLAUDE.md`](hosts/gcp-builder/CLAUDE.md).

---

## Environment

- **Dev machine:** NixOS (`main`).
- **Dev shell:** `nix develop` — provides `deploy-rs`, `nixos-anywhere`, `nixd`, `statix`, `deadnix`, `sops`, `ssh-to-age`, `vulnix`, `direnv`, and the flake-managed pre-commit hook tooling.
- **Per-project shells:** `direnv` enabled — use `use flake` in `.envrc`.
- **Git hooks:** `nix develop` installs a `commit-msg` hook that strips `Co-authored-by:` trailers to keep history single-author.
- **Git is for version control only, not deployment.**

## Deploy Commands

- **`main`:** `nh os switch --hostname main .` (alias: `rebuild`).
- **`mac`:** `deploy '.#mac'` from `main`; local fallback `nh os switch --hostname mac .`.
- **`homeserver-gcp`:** `deploy '.#homeserver-gcp'` for ongoing updates.
  `scripts/deploy-gcp.sh` is **provisioning/reinstall only** (Terraform apply +
  `nixos-anywhere`), not an ongoing-deploy alias. Note `deploy-rs` can appear
  silent/hung in non-interactive sessions; fall back to a manual closure deploy
  (`nix build` the system, `nix copy` the closure, then `switch-to-configuration`).
- **`gcp-builder`:** `deploy '.#gcp-builder'` for ongoing updates (start the VM
  first; it is normally powered off). Provision once via
  [`hosts/gcp-builder/CLAUDE.md`](hosts/gcp-builder/CLAUDE.md). It is an on-demand
  Nix remote builder, not a service host — `main` starts it transparently for
  heavy builds (see `scripts/validate.sh`) and it self-powers-off when idle.
- **`user@wsl`:** `home-manager switch --flake .#user@wsl`.

Module topology, persistence model, and the agent-maintenance sudo allowlist
are documented per host under `hosts/*/CLAUDE.md`. The host registry
(`lib/hosts.nix`) is the single source of truth for system, deploy, tailnet,
Home Manager, backup, and hardware identifiers.

## Validation Shortcuts

| Command                                         | Purpose                                                |
| ----------------------------------------------- | ------------------------------------------------------ |
| `bash scripts/validate.sh flake-eval`           | Fast evaluation gate (`nix flake check --no-build`).   |
| `bash scripts/validate.sh light`                | Deploy checks, invariants, sops bootstrap, lib tests.  |
| `bash scripts/validate.sh hosts`                | Build every host system closure.                       |
| `bash scripts/validate.sh host <name>`          | Build a single host closure.                           |
| `bash scripts/validate.sh profile-tests`        | Build all profile-specific NixOS tests.                |
| `bash scripts/validate.sh smoke-homeserver-gcp` | Booted smoke test for the homeserver routing surface.  |
| `bash scripts/validate.sh package all`          | Build CI package outputs and installer ISO.            |
| `bash scripts/validate.sh heavy`                | Full KVM-backed suite.                                 |
| `bash scripts/validate.sh cve-reports`          | CVE scan reports for each host.                        |
| `statix check .` / `deadnix .`                  | Nix lint.                                              |
| `pre-commit run --all-files`                    | Full hook set (treefmt, shellcheck, statix, deadnix…). |

Validate only what you changed: if `main` changed, build `main-ci`; if
`homeserver-gcp` changed, build its closure; if shared profiles changed, build
all affected hosts.

## CI

- Weekly `flake.lock` updates (`flake-update.yml`) auto-merge if `merge-gate` passes.
- `merge-gate` consolidates flake evaluation, light checks, package builds,
  host builds, and selected smoke/profile tests into one required status for
  branch protection.

## Agents

- **Claude Code** — all `.nix` changes, deployments, secrets.
- **Gemini CLI** — documentation only (`.md` files), consistency checks, README updates.
- **Edit/Bash guards** — `.claude/hooks/guard-edits.sh` and
  `.claude/hooks/guard-bash.sh` (PreToolUse, wired in `.claude/settings.json`)
  are the safety net for bypass-permissions mode. The edit guard _denies_ direct
  edits to `*.enc`/`*.age`/`secrets/**`/the age key (use `sops`) and _asks_
  before editing any `disko.nix`. The Bash guard _asks_ before catastrophic
  block-device ops (`dd`/`mkfs`/`wipefs`/partitioning), LUKS format/erase, and
  recursive `rm` of a top-level path. A blocked/prompted action there is by
  design, not a failure.

## Secrets (sops-nix)

Managed with sops-nix + age. Edit secrets with `sops <file>`.

- Personal age key: `~/.config/sops/age/keys.txt`.
- Add a host key: `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub` → append to `.sops.yaml`.
- `.sops.yaml` defines key groups per path regex.
- `boot.initrd.secrets` MUST only point to sops-managed `/run/secrets/*`
  paths (e.g., `config.sops.secrets.X.path`) — enforced by a native NixOS
  assertion in `modules/nixos/profiles/sops-base.nix`.

See [`docs/security.md`](docs/security.md) for the full secrets/exposure model.

## Security Preferences

- **Broad passwordless sudo is for deploy/dev exceptions only.** Current broad
  exceptions are `hosts/mac`, `hosts/homeserver-gcp`, `hosts/gcp-builder`, and
  `modules/nixos/profiles/machine-dev.nix`; treat SSH access to those targets as
  root-equivalent. `gcp-builder` additionally grants its trusted Nix user
  effective root via remote builds, so keep it tailnet-only and key-only.
- **`main` keeps `wheelNeedsPassword = true`** and uses a narrow
  `agentMaintenanceCommands` NOPASSWD allowlist for repeat maintenance commands.
  Do not broaden this to `NOPASSWD: ALL`.
- **Interactive access relies on SSH keys.** Password hashes are still managed
  through sops for console/recovery login. `main` and `mac` expose SSH only
  through Tailscale-scoped firewall rules.
- **Scope secrets appropriately.** Each host should only be able to decrypt the
  secrets it needs, as defined in `.sops.yaml`.

## Preferences

- Incremental changes — don't refactor everything at once.
- Ask before making large structural changes.
- Prefer Home Manager for user-level config over system-level.
- Keep things declarative — avoid imperative workarounds.
- Flag anything that might cause issues on rebuild.
