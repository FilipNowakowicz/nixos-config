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

- [ ] **Spotify/MPRIS controls in Waybar** — show current track, pause/skip via `playerctl`. Must filter to music players only (exclude browsers, video). Design and allowlist TBD.
- [ ] **Clipboard history GUI** — `cliphist` + `fzf` already works; upgrade to a `fuzzel`-based picker for consistency with other menus.

#### Deferred (low urgency or blocked on discussion)

- [ ] **Idle inhibitor toggle** — Waybar button that pauses `hypridle` (e.g. when watching something outside a browser).
- [ ] **Do-not-disturb toggle** — `makoctl mode +dnd` wired to a Waybar button; silences notifications on demand.
- [ ] **GTK/cursor/icon theming** — wire `gtk.theme`, `cursorTheme`, and an icon pack (e.g. Papirus) through home-manager so all apps match the active theme. Discuss alongside theme studio.
- [ ] **Screenshot workflow** — `satty` for annotation after `grim` capture; `tesseract` OCR pipeline outputting to clipboard.
- [ ] **Keybinding cheat sheet** — auto-generated popup from `hyprland.conf` binds, shown via `Super+?`.

### Goal 02 — Config dashboard wave 2

Keep the generated inventory homepage useful as the repo grows.

- [ ] Add validation command context for hosts and shared checks.
- [ ] Show dependency context for unfinished goals without turning the page into a kanban archive.
- [ ] Surface richer host/service relationships where they help answer "what depends on this?" quickly.

### Homeserver (GCP)

`homeserver-gcp` has its own ordered roadmap in
[docs/homeserver-goals.md](./homeserver-goals.md). Keep detailed homeserver
sequencing there so this file remains a project-level index. Completed
homeserver milestones are documented in `README.md`, `docs/operations.md`,
`docs/security.md`, and `docs/restore-drill.md` rather than staying in the
active roadmap.
