# NixOS Flake Configuration

Personal NixOS flake for an endgame, reproducible setup.
Prefer clean, idiomatic Nix over quick fixes. Suggest better
approaches proactively. Explain why, not just what.

For repository overview and structure see [`README.md`](README.md).
For deeper context see [`docs/architecture.md`](docs/architecture.md),
[`docs/operations.md`](docs/operations.md), and
[`docs/security.md`](docs/security.md). Before changing, deploying or
debugging a host, read its runbook (Codex does not load these on its own):
[`hosts/main/CLAUDE.md`](hosts/main/CLAUDE.md),
[`hosts/homeserver-gcp/CLAUDE.md`](hosts/homeserver-gcp/CLAUDE.md),
[`hosts/gcp-builder/CLAUDE.md`](hosts/gcp-builder/CLAUDE.md).

---

## Environment

- **Dev machine:** NixOS (`main`).
- **Dev shell:** `nix develop` — provides `deploy-rs`, `nixos-anywhere`, `nixd`, `statix`, `deadnix`, `sops`, `ssh-to-age`, `vulnix`, `direnv`, and the flake-managed pre-commit hook tooling.
- **Bare agent shells lack repo tooling** (`sops`, `statix`, …): run repo
  scripts and checks as `nix develop -c <cmd>`, and one-off tools as
  `nix shell nixpkgs#<pkg> -c <cmd>`. `python3` on PATH is uv's managed 3.12
  (`home/profiles/python-development.nix`); projects use `uv run`.
- **Git hooks:** `nix develop` installs a `commit-msg` hook that strips `Co-authored-by:` trailers to keep history single-author.
- **Fresh linked worktrees** (`~/.local/share/worktrees/nix/*`, per the global worktree rule)**:** a `codex/*` branch may already be checked out in another worktree (`git worktree list`), and `.pre-commit-config.yaml` is flake-generated so a worktree never entered via `nix develop` lacks it — commit there with `--no-verify`, but never use `--no-verify` to skip a real lint failure in the primary checkout.
- **Lost worktree recovery.** If a worktree disappears before its work is committed, inspect `git fsck --no-reflogs --dangling` and recover matching blobs with `git cat-file` before `git worktree prune` drops the remaining worktree metadata and index.
- **Git is for version control only, not deployment.**

## Deploy Commands

- **`main`:** `nh os switch --hostname main .` (alias: `rebuild`) interactively.
  Agents and other non-interactive sessions use `sudo nixos-switch-main`
  (add `--remote` to build on `gcp-builder` after `bash scripts/on-builder.sh true`
  starts it), a narrow NOPASSWD wrapper.
- **`homeserver-gcp`:** every merge to `main` that changes its closure deploys
  it automatically (the `Deploy homeserver-gcp` workflow); do not also deploy by
  hand. `deploy '.#homeserver-gcp'` is for when that workflow cannot run; if
  `deploy-rs` hangs silently in a non-interactive session, do a manual closure
  deploy (`nix build`, `nix copy`, `switch-to-configuration`).
  `scripts/deploy-gcp.sh` is **provisioning/reinstall only**.
- **`gcp-builder`:** `deploy '.#gcp-builder'` for ongoing updates (start the VM
  first; it is normally powered off). Provision once via
  [`hosts/gcp-builder/CLAUDE.md`](hosts/gcp-builder/CLAUDE.md). It is an on-demand
  Nix remote builder, not a service host — `scripts/validate.sh` runs on it
  automatically, `rebuild --remote` builds `main` on it, and it self-powers-off
  when idle. Use `bash scripts/on-builder.sh <command>` for other heavy commands.
- **`on-worker` jobs** (long CPU-heavy work from any repo, `on-worker run -- CMD`)
  run on `gcp-builder` too, as its unprivileged `jobs` user, with builds at a
  lower CPU weight (#592); see the Batch jobs section of
  [`hosts/gcp-builder/CLAUDE.md`](hosts/gcp-builder/CLAUDE.md#batch-jobs).

Module topology, persistence model, and the agent-maintenance sudo allowlist
are documented per host under `hosts/*/CLAUDE.md`. The host registry
(`lib/hosts.nix`) is the single source of truth for system, deploy, tailnet,
Home Manager, backup, and hardware identifiers.

## Validation Shortcuts

`bash scripts/validate.sh --help` lists the commands (`flake-eval`, `light`,
`host <name>`, `profile-tests`, `heavy`, …); the check and test lists behind
them come from the flake. Nix lint is `statix check .` / `deadnix .`, and
`pre-commit run --all-files` runs the full hook set.

For repo changes, use the `nix-verification-loop` skill to choose the smallest
meaningful validation command. Validate only what you changed: if `main`
changed, build `main-ci`; if `homeserver-gcp` changed, build its closure; if
shared profiles changed, build all affected hosts.

## CI

- Weekly `flake.lock` updates (`flake-update.yml`) auto-merge if `merge-gate` passes.
- `merge-gate` consolidates flake evaluation, light checks, package builds,
  host builds, and selected smoke/profile tests into one required status for
  branch protection.

## Agents

- **Claude Code and Codex CLI** both do full repo work here from this one
  `CLAUDE.md` (Codex reads it through `.codex/config.toml`). Do not add
  `CODEX.md`/`AGENTS.md` copies.
- **Skills** — repo skills live in `.agents/skills/` (Claude reads them through
  the `.claude/skills` symlink) and both agents list them by description, so
  they are not repeated here. Personal cross-repo skills live in
  `home/files/agents/skills/` (`home/profiles/agent-skills.nix`). The global
  instruction file for both agents is rendered from
  `home/files/agents/global-development.md`
  (`home/profiles/python-development.nix`).
- **Hooks** — `.claude/hooks/` guards, wired for both agents
  (`.agents/scripts/check-agent-sync.sh` fails when they drift): edits to
  secrets are denied (use `sops`); `disko.nix` edits, destructive block-device
  or LUKS ops, recursive `rm` of a top-level path, `gh pr merge --admin`, and
  (Claude only) worktree subagents spawned from a dirty checkout all ask first.
  `format-before-commit.sh` runs `nix fmt` on changed files and stops a
  `git commit` that would fail CI formatting; `session-context.sh` tells a new
  session which checkout and branches are in use. A blocked or prompted action
  is by design, not a failure.

## Learning Candidates

Lessons go to an inbox outside git (`~/.local/state/agent-learning/inbox/`).
Each Friday `agent-learning-weekly` mines the week's Claude and Codex
sessions for more (Codex), then a reviewer that did not write them (Claude
Opus, fresh worktree) verifies and promotes or rejects them in one PR, which
auto-merges via `merge-gate` when it only touches the agent surface. Promotion
prefers assertion/test > hook > skill > subagent > prose. See
[`.agents/learning/README.md`](.agents/learning/README.md).

## Secrets (sops-nix)

Managed with sops-nix + age. Edit secrets with `sops <file>`.

- Personal age key: `~/.config/sops/age/keys.txt`.
- Add a host key: `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub` → append to `.sops.yaml`.
- `.sops.yaml` defines key groups per path regex.
- `boot.initrd.secrets` MUST only point to sops-managed `/run/secrets/*`
  paths (e.g., `config.sops.secrets.X.path`) — enforced by a native NixOS
  assertion in `modules/nixos/profiles/sops-base.nix`.
- **Rotate or generate secrets with `bash scripts/rotate-secret.sh`**
  (`sshkey`, `set`, `random`, `password`): it keeps values byte-exact, stages
  plaintext in a trap-cleaned scratch dir, and re-verifies the decrypt. Never
  chain keygen, `sops -e` and `shred` as separate shell commands; a failed
  `sops` once let `shred` destroy the only copy of a new key.

See [`docs/security.md`](docs/security.md) for the full secrets/exposure model.

## Security Preferences

- **Broad passwordless sudo is for deploy/dev exceptions only.** Current broad
  exceptions are `hosts/homeserver-gcp` and `hosts/gcp-builder` (for `user`;
  the builder's `jobs` account has no sudo);
  treat SSH access as `user` to those targets as root-equivalent. `gcp-builder`
  additionally grants its trusted Nix user effective root via remote builds, so
  keep it tailnet-only and key-only.
- **`main` keeps `wheelNeedsPassword = true`** and uses a narrow
  `agentMaintenanceCommands` NOPASSWD allowlist for repeat maintenance commands.
  Do not broaden this to `NOPASSWD: ALL`.
- **Interactive access relies on SSH keys.** Password hashes are still managed
  through sops for console/recovery login. `main` exposes SSH only
  through Tailscale-scoped firewall rules.
- **Scope secrets appropriately.** Each host should only be able to decrypt the
  secrets it needs, as defined in `.sops.yaml`.

## Preferences

- Other agents share `~/nix`: edit in a worktree
  (`~/.local/share/worktrees/nix/<branch>`), open a PR, and merge only when
  the user asks; never `--admin` unless they say so.
- Large or structural changes route through an issue + PR rather than a live
  ask. One issue (and usually one PR) per problem; do not split related fixes
  into many issues.
- UI changes (quiet shell, Hyprland): switch `main` from the branch and let the
  user try it before merging.
- Ask before using the user's real screen or changing TTY.
- Prefer Home Manager for user-level config over system-level.
- Keep things declarative — avoid imperative workarounds.
- Flag anything that might cause issues on rebuild.
- Guard a NixOS submodule option with `lib.mkIf` at the attribute level
  (`attr = lib.mkIf cond { ... }`), never on a required leaf; see the comment
  on `exportSystemMetadata` in `modules/nixos/profiles/observability/collectors.nix`.
