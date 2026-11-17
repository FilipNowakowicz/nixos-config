#!/usr/bin/env bash
# Promoted from .agents/learning/candidates/archive/2026-09-26-hyprland-exec-once-daemon-stale.yml
# A daemon Hyprland starts itself survives rebuilds: after a package bump the
# old swayosd server kept running and ignored the new client. Commands that
# hyprland.lua runs on its own (hl.exec_cmd, at start, reload or hotplug) must
# be one-shots; anything long-lived belongs in a systemd user unit, which a
# rebuild restarts. Binds (hl.dsp.exec_cmd) launch apps on request and are fine.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

python3 - home/files/hypr/hyprland.lua <<'PY'
import re
import sys

oneshots = {
    "dbus-update-activation-environment",  # copies variables into systemd, exits
    "hypr-display-mode",                   # applies a monitor layout, exits
    "hypr-spotify-autostart",              # starts Spotify hidden, exits
    "notify-send",                         # posts one notification
}
text = open(sys.argv[1], encoding="utf-8").read()
found = re.findall(r'(?<!dsp\.)\bhl\.exec_cmd\(\s*"([^"\s]+)', text)
if not found:
    sys.exit("hyprland-start-runs-oneshots-only: no hl.exec_cmd calls found; the pattern no longer matches the config")
unknown = sorted(set(found) - oneshots)
if unknown:
    sys.exit(
        "hyprland-start-runs-oneshots-only: hyprland.lua starts " + ", ".join(unknown)
        + " itself. Run a long-lived program as a systemd user unit, or add a one-shot to the list here."
    )
PY
