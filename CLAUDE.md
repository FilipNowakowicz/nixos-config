# NixOS Flake Configuration

Personal NixOS flake for an endgame, reproducible setup.
Prefer clean, idiomatic Nix over quick fixes. Suggest better
approaches proactively. Explain why, not just what.

---

## Environment

- **Dev machine:** NixOS (main)
- **Dev shell:** `nix develop` — provides `deploy-rs`, `nixos-anywhere`, `nixd`, `statix`, `deadnix`, `sops`, `ssh-to-age`, `vulnix`, `direnv`, and the flake-managed pre-commit hook tooling.
- **Per-project shells:** `direnv` enabled — use `use flake` in `.envrc` for automatic environment loading.
- **Deploy (WSL):** `home-manager switch --flake .#user@wsl`
- **Deploy (main):** `nh os switch --hostname main .` (alias: `rebuild`)
- **Deploy (mac):** `deploy '.#mac'` from `main`; local fallback is `nh os switch --hostname mac .`
- **Main storage model:** `main` uses LUKS + Btrfs subvolumes (`@root`, `@home`, `@nix`, `@persist`) with initrd rollback of `@root` from `@root-blank` on every boot. Persistent state is explicit in `hosts/main/impermanence.nix`.
- **Mac role:** `mac` is a 2017 MacBook Air companion workstation with Tailscale-only SSH, Home Manager Syncthing, Input Leap client tooling, and Moonlight for Sunshine streams from `main`.
- **Main backups:** `main` Restic/B2 backup coverage is declared in `hosts/main/default.nix` and includes selected home state plus persisted service identity such as Wi-Fi profiles, Mullvad, Tailscale, Bluetooth, USBGuard, Secure Boot PKI, machine-id, and SSH host key.
- **Agent maintenance sudo:** `main` keeps normal wheel sudo passworded but grants `user` narrow NOPASSWD rules for agent-assisted maintenance commands declared as `agentMaintenanceCommands` in `hosts/main/default.nix`. Do not broaden this to `NOPASSWD: ALL`.
- **Validate flake eval:** `bash scripts/validate.sh flake-eval`
- **Automated updates:** Weekly `flake.lock` updates (`flake-update.yml`); auto-merges if `merge-gate` status check passes.
- **Merge Gate:** Consolidates all required checks (flake-check, invariants, smoke-tests) into a single required status check for branch protection.
- **Module Topology:** `modules/nixos/default.nix` globally imports `profiles/observability/`, `profiles/backup.nix`, `profiles/meta.nix`, `services/systemd-failure-notify.nix`, and `services/hardened.nix` for all hosts. Hosts must explicitly import host-specific profiles (e.g., `desktop`, `security`, `base`) but must NOT re-import the globally-provided ones.
- **Host Registry:** `lib/hosts.nix` is the single source of truth and uses typed schema validation. It includes target architecture (`system`) for multi-arch support.
- **Validate light CI suite:** `bash scripts/validate.sh light`
- **Validate hosts:** `bash scripts/validate.sh hosts`
- **Validate profile tests:** `bash scripts/validate.sh profile-tests`
- **Validate heavy suite:** `bash scripts/validate.sh heavy`
- **Structured generator tests:** `nix build '.#checks.x86_64-linux.lib-generators-structured'`
- **CVE scan:** `bash scripts/validate.sh cve-reports`
- **Lint:** `statix check .` and `deadnix .`
- **Pre-commit (manual run):** `pre-commit run --all-files`
- **Git hooks:** `nix develop` installs a `commit-msg` hook that removes `Co-authored-by:` trailers to keep history single-author.
- **Git** is for version control only, not deployment

---

## Network And Access

- **Tailscale** — used for secure remote access and service mesh.
- **Tailscale ACLs** — generated declaratively from `lib/hosts.nix`.
  - Tags are assigned per-host in the registry (`tailscale.tag`).
  - Current policy intent is explicit: `lib/acl.nix` consumes tags, `acceptFrom`, and `tailnetFQDN` when host-specific policy is needed.
  - Richer host metadata like `ip` and `backup.class` stays outside the ACL output unless host-specific policy is added deliberately.
  - Build/inspect ACLs: `nix build '.#packages.x86_64-linux.tailscale-acl'`.
- **Tailscale Certs** — `homeserver-gcp` uses `tailscale-cert.service` to fetch TLS certificates automatically.

---

## Repository Structure

- `flake.nix` — entry point, defines hosts, home-manager, and deploy-rs nodes
- `lib/hosts.nix` — host registry (single source of truth for all hosts)
- `lib/generators.nix` — typed Alloy HCL generators
- `lib/dashboards.nix` — typed Grafana dashboard builders
- `lib/invariants.nix` — configuration invariant check builders
- `lib/cve-checks.nix` — CVE scanning check builders
- `lib/acl.nix` — Tailscale ACL generator (derives rules from host registry)
- `lib/pubkeys.nix` — centralized SSH public keys
- `docs/architecture.md` — structural rules and module boundaries
- `docs/operations.md` — deployment and validation runbook
- `docs/security.md` — secrets, exposure, and hardening model
- `hosts/main/` — real machine config, disko layout, LUKS/Btrfs, impermanence, Lanzaboote (Secure Boot)
  - `hosts/main/CLAUDE.md` — host-local runbook for impermanence, backups, scoped sudo, and recovery gotchas
- `hosts/mac/` — 2017 MacBook Air companion workstation with Broadcom Wi-Fi, impermanence, sops, and Tailscale
  - `hosts/mac/CLAUDE.md` — host-local runbook for Mac install, deploys, and hardware caveats
- `hosts/homeserver-gcp/` — GCP homeserver (Vaultwarden, Syncthing, LGTM, Nginx, Tailscale, TLS)
- `hosts/installer/` — minimal NixOS ISO config for fresh installs
- `scripts/closure-diff.sh` — compute closure diffs in CI
- `modules/nixos/profiles/` — system profiles (base, desktop, security, observability, observability-client, sops-base, meta, machine-common, machine-dev, impermanence-base, user)
- `modules/nixos/services/` — standalone systemd services (hardened.nix, failure-notify)
- `modules/nixos/hardware/` — hardware drivers and graphics (NVIDIA PRIME)
- `home/profiles/` — home-manager profiles (base, desktop, workstation) plus `workflow-packs/` (browsing, coding, latex, learning)
- `home/theme/` — runtime-swappable themes and Home Manager module
  - `active.nix` is intentionally local state (tracks current theme). On a fresh clone, run:
    `git update-index --skip-worktree home/theme/active.nix`
    To commit a new default: `git update-index --no-skip-worktree home/theme/active.nix`, commit, re-apply.
- `home/files/` — dotfiles and standalone scripts (NIX_REPO injected)
- `home/users/user/` — user Home Manager entry points and host overlays (`home.nix`, `main.nix`, `mac.nix`, `server.nix`, `wsl.nix`, `common.nix`)
- `templates/python/` — reusable Python dev shell template (`nix flake init -t ~/nix#python`); provides python3, uv, ruff, basedpyright; sets `UV_PYTHON_DOWNLOADS=never` and `UV_PYTHON` to pin Python to nixpkgs

---

## Agents

- Claude Code — all .nix changes, deployments, secrets
- Gemini CLI — documentation only (.md files), consistency checks, README updates

---

## Secrets (sops-nix)

Managed with sops-nix + age. Edit secrets with `sops <file>`.

- **Age key:** `~/.config/sops/age/keys.txt`
- **Adding a host key:** `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub` → add result to `.sops.yaml`
- **.sops.yaml:** repo root, defines key groups per path regex
- **Initrd Secrets:** `boot.initrd.secrets` MUST only point to sops-managed paths (e.g., `config.sops.secrets.X.path`). This is enforced by an invariant check.

---

## Security Preferences

- **Broad passwordless sudo is for dev machines and `machine-common` hosts only.**
- **Scoped passwordless sudo on `main` is limited to `agentMaintenanceCommands`** for interactive maintenance; keep the allowlist narrow and command-specific.
- **Interactive access should rely on SSH keys.** Host user password hashes are still managed through sops where declared for login/recovery compatibility. `main` and `mac` expose SSH only through Tailscale-scoped firewall rules.
- **Scope secrets appropriately.** Each host should only be able to decrypt
  the secrets it needs, as defined in `.sops.yaml`.

---

## Preferences

- Incremental changes — don't refactor everything at once
- Ask before making large structural changes
- Prefer home-manager for user-level config over system-level
- Keep things declarative — avoid imperative workarounds
- Flag anything that might cause issues on rebuild
- Validate only what you changed: if `main` changed build `main-ci`, if `homeserver-gcp` changed build its closure, if shared profiles changed build all affected hosts
