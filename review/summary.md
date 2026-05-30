# Remaining Config Review Items

This file is the trimmed review backlog. Completed findings and their fix
prompts were removed from `review/`; only unresolved or intentionally partial
items remain.

## Flake, Lib, CI

- Add remaining registry/security invariants:
  - sops recipient parity with the host registry.
  - impermanent hosts must have matching disko configuration.
  - deploy targets must have tailnet addresses.
  - anonymous specialisations must not retain persistence directories.
  - Mullvad and Tailscale coexistence must keep the documented routing/firewall
    assumptions true.
- Replace the `mainBackupPathsArePersisted` parent-prefix check with roots
  derived from disko/subvolume configuration.

## NixOS Modules

- Make XDG portal routing explicit instead of relying on `common.default = "*"`.
- Add a shared helper for Prometheus textfile metric scripts so backup, restore
  canary, Lynis, and Vulnix jobs do not each hand-roll temp-file writes and
  atomic `mv` logic.
- Add a `systemd-analyze security` profile test for hardened services.
- Future hardening ideas still worth tracking:
  `systemd.oomd`, bootloader/console hardening parity, datasource/backend
  coupling assertions, and automatic failure-notify attachment.

## Main And Mac Hosts

- Add a periodic full restic data-check path, with cost/runtime guardrails.
- Clarify `main` battery/thermal node-exporter collector coverage relative to
  the dashboard.
- Document the USBGuard new-stick procedure for `main`.
- Remaining future host items:
  age-key escrow, declarative `mac` travel mode, initrd/FIDO2 recovery for
  `mac`, and coredump storage policy review on `main`.

## Homeserver And Installer

- Decide how far to take declarative AdGuard: current state is improved, but
  mutable runtime state can still drift.
- Keep backing up stable AdGuard export/staging paths instead of relying on
  DynamicUser private paths; verify restore semantics.
- Write and test a homeserver/Vaultwarden restore runbook.
- Remaining future homeserver items:
  service-level disk quotas, Shielded VM/vTPM/integrity monitoring in
  Terraform, metadata endpoint hardening, and a dedicated GCP network/VPC model.

## Home Manager

- Other still-open cleanup candidates:
  `firefox-private` profile parity, bat/base16 theme provisioning, duplicated
  runtime inputs for Waybar/Kitty/Swaybg/Hyprland, HM fontconfig, GPG or
  secret-service defaults, Mako template generation via Nix instead of shell
  interpolation in `theme-switch.sh`, theme colorscheme defaults in the theme
  loader, and whether to migrate raw Neovim config into `programs.neovim`.

## Tests And Scripts

- Add a sops decryption test for at least one real host.
- Extend runtime security tests for kernel sysctls and SSH hardening.
- Decode and assert the actual observability auth credentials in tests, not
  just that an auth header exists.
- Add generator edge-case coverage for `toAlloyHCL` and ACL ordering/ports.
