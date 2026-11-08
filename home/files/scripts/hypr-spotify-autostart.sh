#!/usr/bin/env bash
# Started once per session by hyprland.lua, which keeps the window hidden.
#
# Spotify aborts when it starts with no tray host and falls back to its old icon
# (see packages/quiet-shell/tray-watcher.py), so wait for the shell to register as one.
# If the shell never does, Spotify stays closed rather than risk that.
set -euo pipefail

command -v spotify >/dev/null || exit 0

for _ in {1..120}; do
  if [[ $(busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher \
    org.kde.StatusNotifierWatcher IsStatusNotifierHostRegistered 2>/dev/null) == "b true" ]]; then
    exec spotify
  fi
  sleep 0.5
done
