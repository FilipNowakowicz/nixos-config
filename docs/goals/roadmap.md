# Roadmap & Backlog

Deferred and intentionally-not-yet-done work. Completed items are removed. Each
item carries a **trigger** or **why-deferred** that justifies revisiting it, so
the repo avoids premature abstraction. Host-specific roadmaps live in
[`homeserver-goals.md`](homeserver-goals.md) and
[`macbook-goals.md`](macbook-goals.md).

---

## Active Candidates

Small, finishable work that does not need a triggering event.

### Larger reliability / security work

The "main ones" — each is a coherent piece of work, not a one-liner.

| Area        | Item                                             | Value / acceptance                                                                                                                                                                                                                                                                                                     |
| :---------- | :----------------------------------------------- | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Alerting    | Consolidated systemd unit-failure **delivery**   | `SystemdUnitFailed` already fires after 2 min (`lib/observability-alerts.nix`); the gap is a single coherent, reliable _off-host delivery_ path so a failure on a degraded box still reaches you. The off-box-liveness half shipped as the homeserver dead-man's-switch; this is the remaining in-guest delivery half. |
| Reliability | Scheduled, _executed_ full-service restore drill | The daily canary already proves a marker round-trip and a Vaultwarden `integrity_check`, so raw restorability is no longer untested. The remaining gap is _full-service_ recovery. Acceptance: a timer/CI job that restores Vaultwarden + Grafana + AdGuard to a scratch target and asserts they come up.              |
| Security    | CVE remediation cadence                          | Scanning exists (`vulnix`, `validate.sh cve-reports`) and deliberately does not alert on `vulnix_cve_total` (whitelist noise). The missing half is the _human loop_. Acceptance: a documented triage cadence (owner + interval) so "we scan" does not become "we scan and never look."                                 |

### Home Manager polish

Low priority, individually cheap — batch rather than track separately. Status
reflects what already exists.

| Item                                                 | Status / acceptance                                                                                                                                                                |
| :--------------------------------------------------- | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Dedupe runtime inputs (Waybar/Kitty/Swaybg/Hyprland) | Single source for shared runtime deps; acceptance: no copy-pasted package lists.                                                                                                   |
| HM fontconfig provisioning                           | bat/base16 theming is **already done** via the custom `home/theme/module.nix` (kitty/waybar/hypr palettes, `bat` `theme = "base16"`); only declarative `fonts.fontconfig` remains. |
| `firefox-private` profile parity                     | A throwaway-profile `firefox-private` launcher already exists; "parity" means bringing the _default_ profile under managed `programs.firefox` too. Low value.                      |
| GPG / secret-service defaults                        | `gnome-keyring` (secret-service) is wired at system level; the gap is HM-level `services.gpg-agent` / `programs.gpg` defaults.                                                     |

The Mac `broadcom_sta` (`wl`) posture decision is a candidate too, tracked in
[`macbook-goals.md`](macbook-goals.md).

---

## Deferred — Waiting On A Trigger

These are real but should not start until a concrete need appears.

| Item                                                                 | Trigger to revisit                                                 |
| :------------------------------------------------------------------- | :----------------------------------------------------------------- |
| Declarative `mac` travel mode                                        | Travel use becomes frequent enough to justify a dedicated profile. |
| initrd / FIDO2 recovery for `mac`                                    | A recovery scenario actually requires it.                          |
| `config.specialisation` alternate boot entries (e.g. gaming profile) | A second concrete boot profile is wanted.                          |
| Service-level disk quotas (homeserver)                               | A service shows unbounded disk growth.                             |
| Metadata endpoint hardening (GCP)                                    | Metadata-sourced secrets/SSRF surface becomes a concern.           |
| Dedicated GCP network / VPC model                                    | More than one provider service needs network separation.           |

---

## Cross-System / Multi-Arch Support

Status: postponed until the first non-`x86_64-linux` host is planned or added.

The active fleet is `x86_64-linux` only. Per-host `system` metadata already lives
in `lib/hosts.nix`; broadening checks now would add CI and tooling complexity
before there is a concrete second architecture to validate.

Scope when revisited:

- `nix flake check --all-systems`
- `aarch64-linux` evaluation readiness
- Gating or refactoring x86-specific VM and test tooling

Trigger: a real ARM host is planned or added to `lib/hosts.nix`.

---

## Deferred Strategic Goals

### Full Service Composition DSL

Status: deferred. **Canonical entry for this goal** — homeserver-goals.md links
here. A DSL that emits Nginx locations, firewall rules, backup paths, hardening,
and Alloy scrape config could be useful, but premature abstraction would hide
important security and exposure decisions. Wait until there are enough real
services to reveal the right shape.

Trigger: two or three additional services repeat the same cross-cutting pattern
and the manual edits become error-prone.

### AppArmor Or Broader MAC Policy

Status: deferred. Mandatory access control can be valuable but has a high tuning
and maintenance cost. The current security model gets more immediate value from
systemd sandboxing, service-exposure discipline, and restore verification.

Trigger: a specific threat model or service requires confinement beyond systemd
hardening.

### Cloud KMS / Cloud DNS (GCP)

Status: deferred — speculative for a tailnet-only personal homeserver. Neither
has a near-term trigger. Default GCP-managed encryption and Tailscale DNS cover
current needs.

Trigger (KMS): a concrete compliance, key-separation, or rotation-control
requirement. Trigger (DNS): a real public/private/split-horizon naming problem
Tailscale DNS cannot solve cleanly.

---

## Settled / Won't-Do

Recorded so they are not re-proposed:

- **Full flake-parts modular decomposition** — rejected. The flake already uses
  flake-parts where it helps; splitting further is aesthetic at this size.
  Reopen only if flake outputs become hard to understand or contributors
  routinely edit unrelated outputs by mistake.
- **Migrate Neovim to `programs.neovim`** — won't-do. The bespoke `my.neovim`
  module (language packs, a Lua-config generator, per-language LSP/DAP wiring) is
  more capable than `programs.neovim` would be, and already installs config
  declaratively via `xdg.configFile."nvim"` with no out-of-band injection — the
  original "no out-of-band lua/vimrc" acceptance is effectively already met.
  Migrating would regress functionality. Reopen only if the custom generator
  becomes a maintenance burden.

---

## Homeserver Parked Ideas

Status: not active priorities; revisit if manual deploys or secret hygiene
become real pain points.

### Automated Deploy Pipeline

Why parked: the manual deploy flow is currently acceptable, and the repo already
has validation and smoke-test entrypoints without GitHub Actions automation.

Scope when revisited:

- Self-hosted GitHub Actions runner as a NixOS service
- Validation and smoke-test gating before deploy
- Ordered rollout for `homeserver-gcp` and then `main`

### Secret Rotation Ritual

Why parked: rotation is useful but largely procedural and only partly
automatable; the current setup does not justify prioritizing it over active
service and auth work.

Scope when revisited:

- Secret inventory with owner, trigger, and command path
- Rotation checklist through `sops` and deploy
- Optional Grafana visibility for secret-age metadata
