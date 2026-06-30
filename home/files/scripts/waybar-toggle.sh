#!/bin/bash
# SUPER+W: pin / unpin the auto-hide bar.
#
# The waybar-autohide watcher owns actual visibility; this only flips the pin
# flag it reads. Pinned => the bar stays revealed regardless of cursor position;
# unpinned => it follows the top-edge hover behaviour again.
set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/waybar"
PIN_FILE="$STATE_DIR/pinned"
mkdir -p "$STATE_DIR"

if [[ -f $PIN_FILE ]]; then
  rm -f "$PIN_FILE"
else
  : >"$PIN_FILE"
fi
