# Quiet shell

A quiet, auto-hiding desktop shell for Hyprland, built on Quickshell. It replaces
Waybar, the GTK control centre, the launcher and mako once enabled.

Everything goes through `scripts/status.sh` and ordinary system commands, so tests
swap those commands with fakes rather than using a separate test mode.

Fonts: Open Runde (SIL OFL, see `assets/fonts/OFL.txt`).
Icons: Lucide 0.469 (ISC).
