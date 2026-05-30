# Config Review Backlog

Unresolved or intentionally deferred findings. Completed items have been removed.

---

## Easy

- Verify AdGuard backup restore semantics — ensure stable export/staging paths are backed up rather than DynamicUser private paths.

## Medium

- Add a periodic full restic data-check path with cost/runtime guardrails.
- Decide declarative AdGuard scope — current state is improved but mutable runtime state can still drift.
- Write and test a homeserver/Vaultwarden restore runbook.

## Future

**Modules / hardening:**
`systemd.oomd`, bootloader and console hardening parity across hosts, datasource/backend coupling assertions, automatic failure-notify attachment.

**Hosts:**
Age-key escrow, declarative `mac` travel mode, initrd/FIDO2 recovery for `mac`, coredump storage policy review on `main`.

**Homeserver / GCP:**
Service-level disk quotas, Shielded VM / vTPM / integrity monitoring in Terraform, metadata endpoint hardening, dedicated GCP network/VPC model.

**Home Manager:**
`firefox-private` profile parity, bat/base16 theme provisioning, deduplicate runtime inputs for Waybar/Kitty/Swaybg/Hyprland, HM fontconfig, GPG or secret-service defaults, Mako template generation via Nix instead of shell interpolation in `theme-switch.sh`, theme colorscheme defaults in the theme loader, migrate raw Neovim config into `programs.neovim`.
