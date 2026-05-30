# Remaining Config Review Items

This file is the trimmed review backlog. Completed findings and their fix
prompts were removed from `review/`; only unresolved or intentionally partial
items remain.

## NixOS Modules

- Future hardening ideas still worth tracking:
  `systemd.oomd`, bootloader/console hardening parity, datasource/backend
  coupling assertions, and automatic failure-notify attachment.

## Main And Mac Hosts

- Add a periodic full restic data-check path, with cost/runtime guardrails.
- Clarify `main` battery/thermal node-exporter collector coverage relative to
  the dashboard.
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
