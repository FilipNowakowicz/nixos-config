#!/bin/bash
# Auto-hide controller for the waybar pill (macOS menu-bar style).
#
# Reveals the bar when the cursor reaches the top screen edge and retracts it
# when the cursor leaves; SUPER+W pins it open via a flag file (waybar-toggle).
# This watcher is the SINGLE owner of waybar visibility — waybar-toggle only
# flips the pin — so the hover logic and the keybind never fight each other.
set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/waybar"
PIN_FILE="$STATE_DIR/pinned"
RELOAD_FILE="$STATE_DIR/needs-reload"
mkdir -p "$STATE_DIR"

REVEAL_PX=4 # cursor this close to the top edge reveals the bar
KEEP_PX=52  # while shown, cursor below this retracts it (bar height + margin)
POLL="0.12"
RESYNC_EVERY=10 # reconcile internal state with the real bar every N ticks

waybar_pids() {
  ps -eo pid=,comm=,args= |
    awk '$2 == ".waybar-wrapped" && $3 == "waybar" { print $1 }
         $2 == "waybar" { print $1 }' | sort -n -u
}

# Visible == present at Hyprland layer level 2 ("top"); the same authoritative
# check waybar-toggle and theme-switch use.
waybar_visible() {
  hyprctl layers 2>/dev/null | awk '
    /^[[:space:]]*Layer level 2/  { in_top = 1; next }
    /^[[:space:]]*Layer level/    { in_top = 0; next }
    in_top && /namespace: waybar/ { found = 1; exit }
    END { exit !found }'
}

cursor_y() {
  local pos
  pos=$(hyprctl cursorpos 2>/dev/null) || return 1
  printf '%s\n' "${pos##*, }"
}

signal_toggle() {
  while IFS= read -r pid; do
    [[ -n $pid ]] || continue
    kill -USR1 "$pid" 2>/dev/null || true
  done < <(waybar_pids)
}

show_bar() {
  signal_toggle
  # Consume a theme reload that was deferred while the bar was hidden.
  if [[ -f $RELOAD_FILE ]]; then
    sleep 0.2
    while IFS= read -r pid; do
      [[ -n $pid ]] || continue
      kill -USR2 "$pid" 2>/dev/null || true
    done < <(waybar_pids)
    rm -f "$RELOAD_FILE"
  fi
}

visible=false
waybar_visible && visible=true
tick=0

while true; do
  if ! y=$(cursor_y); then
    sleep 0.5
    continue
  fi

  # Periodically reconcile with the real bar state (theme reloads can re-hide it).
  if ((tick % RESYNC_EVERY == 0)); then
    visible=false
    waybar_visible && visible=true
  fi
  tick=$((tick + 1))

  if [[ -f $PIN_FILE ]]; then
    want=true
  elif $visible; then
    [[ $y -le $KEEP_PX ]] && want=true || want=false
  else
    [[ $y -le $REVEAL_PX ]] && want=true || want=false
  fi

  if $want && ! $visible; then
    show_bar
    visible=true
  elif ! $want && $visible; then
    signal_toggle
    visible=false
  fi

  sleep "$POLL"
done
