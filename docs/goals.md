# Project Roadmap & Goals

This document tracks the evolution of this NixOS configuration, from immediate next steps to longer-term directions.

---

## Active

### Goal 01 — Desktop "daily driver" profile

Turn `main` into a more intentional workstation layer. Tackled incrementally — each item is independent and shippable on its own.

#### Ready to implement

- [ ] **Bluetooth menu** — replace Blueman (half-screen app) with a `bluetoothctl`-driven `fuzzel` popup: lists paired devices, click to connect/disconnect.
- [ ] **WiFi menu** — replace `networkmanagerapplet` tray with an `nmcli`-driven `fuzzel` popup launched from the Waybar network module.
- [ ] **Volume menu** — Waybar audio module opens a thin custom popup for output/input switching (via `wpctl` or `pavucontrol`), separate from the OSD.

#### Needs design discussion

- [ ] **App launcher** — existing launchers (wofi, rofi, fuzzel) all available; design direction TBD.
- [ ] **Spotify/MPRIS controls in Waybar** — show current track, pause/skip via `playerctl`. Must filter to music players only (exclude browsers, video). Design and allowlist TBD.
- [ ] **Clipboard history GUI** — `cliphist` + `fzf` already works; upgrade to a `fuzzel`-based picker for consistency with other menus.

#### Deferred (low urgency or blocked on discussion)

- [ ] **Idle inhibitor toggle** — Waybar button that pauses `hypridle` (e.g. when watching something outside a browser).
- [ ] **Do-not-disturb toggle** — `makoctl mode +dnd` wired to a Waybar button; silences notifications on demand.
- [ ] **GTK/cursor/icon theming** — wire `gtk.theme`, `cursorTheme`, and an icon pack (e.g. Papirus) through home-manager so all apps match the active theme. Discuss alongside theme studio.
- [ ] **Screenshot workflow** — `satty` for annotation after `grim` capture; `tesseract` OCR pipeline outputting to clipboard.
- [ ] **Keybinding cheat sheet** — auto-generated popup from `hyprland.conf` binds, shown via `Super+?`.

### Homeserver (GCP)

`homeserver-gcp` is the active homeserver running on GCP (GCE). Vaultwarden, Syncthing, LGTM stack, Nginx, Tailscale, and Backblaze B2 backups are all live.

- [ ] **Automated deploy pipeline** — add a self-hosted GitHub Actions runner as a NixOS service on the homeserver (always-on, has KVM). Extend smoke test to probe live endpoints (Grafana login, ingest auth). Add automated deploy job that deploys homeserver-gcp then main in order after smoke test passes. CI already builds the relevant closures and publishes them to the signed R2 binary cache. Secrets rotation (ingest credentials, Grafana admin password) becomes a cheap add-on once deploy is automated — Tailscale auth key stays manual.
- [ ] **Local DNS & ad-blocking** — deploy AdGuard Home on the GCE VM, integrated with Tailscale MagicDNS for network-wide privacy.
- [ ] **LGTM tuning** — expand dashboards and alerts, tune retention/cardinality for long-running operation. Add alerting rules for disk usage >80%, service restarts, and backup failures.
- [ ] **Host introspection → LGTM** (medium) — auditd + osquery or lynis timer → logs to Loki → dashboards. Pairs with the existing observability stack; proves the LGTM investment for something beyond infra metrics.
- [ ] **Service composition DSL** (medium–substantial) — a module like `services.app.<name> = { package, port, backup, observe, harden }` that auto-wires sandboxing, systemd hardening, log shipping, and restic targets. Eliminates the "add a service → remember to also wire 5 cross-cutting things" tax.
- [ ] **Expand typed generator approach to additional domains (for example nginx vhosts/timers).**
- [ ] **Create secret rotation ritual/checklist + age/rotation observability metric.**
