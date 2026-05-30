# NixOS Config Review — Summary

Reviewed by 6 parallel Opus 4.8 agents across all domains. Each domain has a
`*-findings.md` (severity-tagged) and `*-fix-context.md` (ready-to-use fix prompt)
in this directory.

## Status after PR 62

PR 62 addresses most of the original P0 fix batches and a focused subset of the
P1/P2 items. Status markers below mean:

- `[DONE]` The PR contains a matching code/config change.
- `[PARTIAL]` The PR improves the issue but does not fully satisfy the original
  finding.
- `[OPEN]` No matching PR 62 change was found in the current diff.

---

## P0 — Broken / Silent Failure (fix before next deploy)

### Security

**[DONE][D] GCP edge firewall is open to the internet**
`infra/main.tf:9-21` — Terraform only adds the Tailscale UDP rule. GCP's
auto-created `default-allow-ssh` (TCP/22 from 0.0.0.0/0) is never removed.
Public SSH is blocked _only_ by the in-guest nftables rule. With
`wheelNeedsPassword = false` on homeserver, a firewall regression = passwordless
root from the internet. The "Tailscale-only SSH" claim in CLAUDE.md is false at
the network edge.
→ Fix: `google_compute_firewall` resource removing `default-allow-ssh`, or GCP
Console. See `D-homeserver-installer-fix-context.md`.

**[DONE][C] Anonymous mode persist directories not cleared**
`hosts/main/anonymous.nix` — the anonymous specialisation `mkForce`s only
`.files` (to drop machine-id) but leaves the full `.directories` persist list
untouched. Tailscale identity, saved Wi-Fi credentials, Bluetooth pairings, and
fingerprint data are all still bind-mounted from `/persist` in anonymous mode,
directly contradicting the amnesic claim.
→ Fix: explicitly override `.directories = []` (or a safe minimal subset) in the
anonymous specialisation. See `C-hosts-main-mac-fix-context.md`.

### Monitoring / Alerting

**[DONE][B+D] Alertmanager routes all alerts to a null receiver**
`modules/nixos/profiles/observability/alerts.nix:127-142` — every one of the 9
alert rules (backup stale, CVE found, unit failed, probe failed) routes to a
`null` Alertmanager receiver. Grafana has no contact points provisioned either.
The entire alerting stack is a write-only system. On an unattended server this
is the single most operationally dangerous gap.
→ PR 62 adds an Alertmanager webhook option and `homeserver-gcp` now wires it
to a sops-backed off-host webhook URL. See
`B-modules-fix-context.md` and `D-homeserver-installer-fix-context.md`.

**[DONE][D] Backup success metric stamped on failure**
`hosts/homeserver-gcp/backups.nix:4-12` — the restic timestamp metric is written
via `ExecStartPost` which runs regardless of the main `ExecStart` exit code. A
failed or partially-failed backup still advances `restic_last_backup_timestamp_seconds`,
keeping `ResticBackupStale` green and the status badge healthy.
→ Fix: write the metric inside the restic command or gate it on exit code.
See `D-homeserver-installer-fix-context.md`.

**[DONE][F] `systemd-failure-notify.nix` broken end-to-end**
The notify script reads `$SYSTEMD_UNIT` (not a real systemd-exported env var —
always empty string) and the template's `%i` instance specifier is never passed
to `ExecStart`. Every failure notification fires with a blank service name.
No test exists so this looks healthy. Applied on both `main` and `mac`.
→ Fix: use `%i` in `ExecStart` or pass the unit name via `Environment=`.
See `F-tests-scripts-fix-context.md`.

### CVE Scanning

**[DONE][A+F] CVE scanning is completely inert**
`lib/cve-checks.nix` + `validate.sh cve-reports` exist and are advertised in
CLAUDE.md and README as an operated security signal, but:

- No `.github/workflows` job runs it — the weekly `flake.lock` auto-merge has
  zero CVE guard.
- The check exits 0 unconditionally (`|| true`).
- It has a redirect bug: `2>&1 >> $out` sends vulnix stderr findings to the
  terminal, not the report file.
- Only scans `main`, omitting internet-adjacent `homeserver-gcp`.
  → PR 62 adds a scheduled/flake.lock PR workflow, fixes the stderr capture,
  and scans both `main` and `homeserver-gcp`. Staying informational (not
  merge-gating) is intentional: vulnix advisories are noisy and transitive;
  a hard gate would create friction that gets bypassed. Reports remain visible
  without blocking merges.
  See `A-flake-lib-fix-context.md`.

### Invariants / CI

**[DONE][A] Invariant checks the wrong closure**
`flake/checks.nix` — `invariants-main` validates `allNixosConfigs.main` (full
config), but CI and `validate.sh hosts` build `main-ci` (with `profiles.ci =
true` / `skipHeavyPackages`). The security-critical invariants (no passwordless
sudo, Tailscale-only SSH, USBGuard) are checked on a sibling evaluation that is
not the artifact CI actually ships.
→ Fix: run invariants against `main-ci` in CI, or ensure the invariants are
evaluated on the same attrpath CI builds. See `A-flake-lib-fix-context.md`.

### NixOS Module Behavior

**[DONE][B] Hardening baseline silently overridden for key services**
`modules/nixos/services/hardened.nix:106-114` — all sandbox options are set with
`lib.mkDefault` so that "nixpkgs modules win." For nginx, vaultwarden, and other
services that set the same keys upstream, the hardened values are silently
discarded. The module advertises a strict hardening baseline that is not in
force for the services that need it most.
→ Fix: use `lib.mkForce` for the core security settings, or document explicitly
which services override which keys. See `B-modules-fix-context.md`.

### Home Manager

**[DONE][E] Theme system never reaches Neovim**
`home/neovim/generators/lua-config.nix` — `ui.lua` hardcodes `gruvbox-material`
colorscheme. All 8 themes correctly theme the terminal, bars, and borders but
the editor stays gruvbox regardless of active theme.

**[DONE][E] Kitty ANSI 16-color palette hardcoded gruvbox**
`home/theme/module.nix:111-128` — for every theme, the 16 ANSI slots are the
gruvbox palette. All TUI apps (lazygit, btop, bat, `:terminal`) ignore the
active theme.

**[DONE][E] TexLab LSP installed but never started**
`home/neovim/packs/tex.nix` — `lsp.enable = []` so `vim.lsp.enable` never
includes texlab. TeX LSP completion and diagnostics are dead despite the binary
being on PATH.

### Hosts

**[DONE][C] mac fail2ban ban database resets every reboot**
`hosts/mac/impermanence.nix` — `/var/lib/fail2ban` is persisted on `main` but
not on `mac`. Every reboot clears all bans.

---

## P1 — Significant Gaps / Security

| Domain | Finding                                                                                                                                                                                                    |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A      | [DONE] CLAUDE.md claims `boot.initrd.secrets` is enforced by an invariant — no such invariant exists anywhere in the codebase                                                                              |
| A      | [DONE] `inventory-data.nix` re-implements invariants by hand and has already drifted from the canonical ones in `flake/checks.nix` — shared checks now live in `lib/invariants.nix` and feed both surfaces |
| A      | [DONE] Deploy config applies fixed rollback settings with no per-host `confirmTimeout`; on `mac` (Tailscale-only, ephemeral) magic-rollback can roll back a correct deploy if `tailscale0` comes up slowly |
| B      | [DONE] `machine-dev.nix` broad passwordless sudo + trusted Nix user is unconditional — gated only by a comment. `microvm-guest.nix` imports it transitively. Should be `mkIf`-gated                        |
| B      | [DONE] `nix-trusted-users.nix` only warns (not asserts) on root-equivalent broad trust — a policy that can silently pass CI                                                                                |
| B      | [DONE] `security.nix` missing standard hardening sysctls: `kptr_restrict`, `dmesg_restrict`, `yama.ptrace_scope`, `bpf_jit_harden`, `kexec_load_disabled`                                                  |
| C      | [DONE] Libvirt/KVM images (`/var/lib/libvirt`) persisted on `main` but not in the restic/B2 backup list — disk loss destroys them with no off-host copy                                                    |
| C      | [DONE] `restic-check-local` orders on `network-online.target` but `main` force-disables both wait-online providers — the network dependency is a no-op                                                     |
| D      | [DONE] No HSTS, CSP, or X-Frame-Options on nginx virtualHosts serving Vaultwarden (password manager); PR 62 adds HSTS/XFO/XCTO/Referrer-Policy and CSP                                                     |
| D      | [DONE] AdGuard `mutableSettings = true` — blocklists, admin creds, client rules are wizard artifacts on disk, not in git. Blocklists and user rules are now declared                                       |
| D      | [DONE] No TLS certificate expiry monitoring — a silent renewal failure breaks all HTTPS at ~90 days, surfacing only via the null-receiver alert                                                            |
| D      | [DONE] `hosts/installer/default.nix` opens TCP/22 globally with `PermitRootLogin = "yes"` and `PasswordAuthentication` not explicitly set to `false`, no hardening profile                                 |
| E      | [DONE] Treesitter/`telescope-fzf-native` need a C compiler at runtime; works on workstation by accident (gcc in heavy packages) but silently breaks LSP features on WSL                                    |
| E      | [DONE] `homeConfigurations.user` (standalone) imports the desktop role without the `desktop.nix` profile — half-configured desktop (waybar/hypr but no kitty/firefox/GTK)                                  |
| E      | [DONE] `workstation.nix` profile is entirely dead — no host lists it; the `lib/hosts.nix` comment referencing it is stale                                                                                  |
| F      | [DONE] PromQL alert rules (`alerts.nix`) are never validated with `promtool check rules` — a metric-name typo ships silently and alerts never fire                                                         |
| F      | [SKIP] No test that impermanence actually loses state on reboot — complexity (KVM + full boot + btrfs) outweighs value; upstream module is well-tested; misconfigurations are better caught by code review |
| F      | [DONE] `agentMaintenanceCommands` NOPASSWD sudo allowlist (a real privesc surface) has no test                                                                                                             |
| F      | [DONE] `installer` host is built by no CI job                                                                                                                                                              |

---

## P2 — Optimization / Quality

| Domain | Finding                                                                                                                                                                                                             |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A      | [DONE] `ip` field in host registry is validated, invariant-checked, and inventory-projected but set by no host and consumed by no module — PR 62 removed part of the stale surface, but inventory still projects it |
| A      | [DONE] `installer-iso`, `control-center`, and `tailscale-acl` outputs have zero CI build coverage — PR 62 adds installer coverage; control-center/tailscale-acl remain open                                         |
| A      | [DONE] Dev shell missing `nh` (documented `rebuild` alias), `jq`, and `git`                                                                                                                                         |
| B      | [DONE] Grafana dashboards provisioned from store are `editable=true; disableDeletion=false` — UI edits silently lost on redeploy                                                                                    |
| B      | [DONE] `impermanence-base.nix` rollback-root parses btrfs output with fragile `cut -f 9 -d ' '` (field position is version-dependent)                                                                               |
| B      | [DONE] Backup `restic check` never tests an actual restore; backup invariant doesn't verify `paths != []`, so empty backup stamps fresh timestamp                                                                   |
| C      | [DONE] `tailscale-bypass-routing` script exits 0 on all errors — firewall exceptions for Tailscale could silently fail to apply                                                                                     |
| D      | [DONE] Grafana SQLite database backed up live (risk of torn-DB backup)                                                                                                                                              |
| D      | [DONE] AdGuard state at dynamic UID path backed up raw (UID mismatch on restore)                                                                                                                                    |
| D      | [DONE] nginx access logs not shipped to Loki — no log data for incident response                                                                                                                                    |
| E      | [DONE] GTK theme never set — GTK apps fall back to stock Adwaita despite `gnome-themes-extra` being installed                                                                                                       |
| E      | [DONE] `clangd` hardcoded-enabled in `lsp.lua` with no matching neovim pack; `clang-tools` only present behind `skipHeavyPackages`                                                                                  |
| E      | [DONE] `mako` notification config has three sources of truth (theme module + inline block in `theme-switch.sh`)                                                                                                     |
| F      | [DONE] Smoke test hard-fails (vs skips) when `/dev/kvm` is unavailable                                                                                                                                              |
| F      | [DONE] Three drifting copies of the secret-scan regex across two scripts and the pre-commit hook — PR 62 unifies the scanner/pre-commit pattern; `check-secrets-directory.sh` remains separate                      |

---

## P3 — Future Additions Worth Implementing

| Domain | Suggestion                                                                                                                   |
| ------ | ---------------------------------------------------------------------------------------------------------------------------- |
| A      | Add invariants: sops recipient ↔ host registry parity; impermanence host must have disko; deploy target must have tailnet IP |
| B      | Add `systemd.oomd` configuration to the hardening profile (modern OOM handling)                                              |
| C      | [DONE] Automated restore canary (daily restic restore of a single file to a tmp path + metric)                               |
| C      | Age key escrow — back up the sops age private key to a separate secure location                                              |
| C      | mac: declarative travel-mode specialisation (enable initrd SSH + disable Tailscale firewall restriction before travel)       |
| D      | Disk quota isolation per service on homeserver (separate subvolumes for Grafana, AdGuard, Loki)                              |
| D      | GCP Shielded VM configuration in Terraform (vTPM, integrity monitoring)                                                      |
| D      | Restore runbook for Vaultwarden specifically — test the procedure at least once                                              |
| E      | `nix-direnv` in base HM profile — given `direnv` is in the dev shell, HM should enable it                                    |
| E      | Git productivity defaults in common.nix (`rebase.autosquash`, `push.autoSetupRemote`, `delta` as pager)                      |
| E      | WSL clipboard provider (`wl-clipboard` or xclip equivalent) for `clipboard=unnamedplus`                                      |
| F      | `actionlint` in pre-commit hooks to lint GitHub Actions YAML                                                                 |
| F      | Invariant: anonymous specialisation must not have persistence directories                                                    |
| F      | Invariant: Mullvad + Tailscale coexistence check (documented as fragile)                                                     |

---

## Cross-Cutting Themes

**1. Monitoring is end-to-end broken.** Alerts fire into a null receiver. Failure
notifications emit blank service names. CVE scanning has no CI hook. All three
problems compound: you can't know when the system is unhealthy.

**2. Security claims not enforced at the code level.** CLAUDE.md describes a tight
security model; several parts (initrd.secrets invariant, GCP firewall, hardening
baseline, anonymous amnesic directories) rely on convention or documentation
rather than code enforcement.

**3. The theme system is a partial implementation.** The architecture is sound but
Neovim, Kitty ANSI colors, and GTK are all wired to hardcoded gruvbox regardless
of the active theme.

**4. CI coverage has structural gaps.** The invariant checks the wrong closure; CVE
scan is unreachable from CI; PromQL rules aren't linted; the installer is never
built.

---

## Parallelizable Fix Batches

The fix-context files are self-contained prompts for fix agents. Suggested grouping
for parallel implementation (no cross-domain file conflicts):

| Batch | Context file                            | Scope                                                                 |
| ----- | --------------------------------------- | --------------------------------------------------------------------- |
| 1a    | `A-flake-lib-fix-context.md`            | CVE scan fix, invariant closure, deploy timeouts, dead `ip` field     |
| 1b    | `B-modules-fix-context.md`              | Hardening `mkForce`, alerting receiver, machine-dev guard, sysctls    |
| 1c    | `C-hosts-main-mac-fix-context.md`       | Anonymous directories, mac fail2ban, backup list                      |
| 1d    | `D-homeserver-installer-fix-context.md` | GCP firewall (Terraform), backup metric, nginx headers, installer SSH |
| 1e    | `E-home-manager-fix-context.md`         | Theme → Neovim, Kitty palette, texlab LSP, GTK theme                  |
| 1f    | `F-tests-scripts-fix-context.md`        | failure-notify fix, promtool check, installer CI job                  |

Batches 1a–1f can run in parallel (each agent works in its own worktree).
The GCP firewall change (1d) may need manual apply via `terraform apply` after
the code is written.
