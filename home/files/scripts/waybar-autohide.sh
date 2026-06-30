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
HOT_W=720   # width of the top-edge reveal hot-zone, centred on each monitor.
# Matches the waybar modules-center box (style.css min-width: 720px),
# which is centred per output and contains the whole visible pill —
# so the reveal only triggers over the bar's footprint, not the full
# top edge. The keep-while-shown check stays width-agnostic so the
# bar never retracts mid-use when the cursor tracks along it.
POLL="0.12"
RESYNC_EVERY=10 # reconcile internal state with the real bar every N ticks

# Per-output geometry, refreshed on resync: parallel arrays of x-offset/width.
MON_X=()
MON_W=()
load_monitors() {
  MON_X=()
  MON_W=()
  local x w
  while read -r x w; do
    MON_X+=("$x")
    MON_W+=("$w")
  done < <(hyprctl monitors 2>/dev/null | awk '
    $2 == "at" && $1 ~ /x[0-9.]+@/ {
      split($1, res, "x"); split($3, off, "x")
      print off[1] + 0, res[1] + 0
    }')
}

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

cursor_pos() {
  local pos
  pos=$(hyprctl cursorpos 2>/dev/null) || return 1
  # cursorpos prints "X, Y"; emit "X Y".
  printf '%s %s\n' "${pos%%,*}" "${pos##*, }"
}

# True when global cursor x falls inside the bar's centred hot-zone on whatever
# monitor it currently sits over.
in_hot_zone() {
  local cx=$1 i mx mw w left right
  for i in "${!MON_X[@]}"; do
    mx=${MON_X[i]}
    mw=${MON_W[i]}
    ((cx >= mx && cx < mx + mw)) || continue
    w=$HOT_W
    ((w > mw)) && w=$mw
    left=$((mx + (mw - w) / 2))
    right=$((left + w))
    ((cx >= left && cx <= right)) && return 0
    return 1
  done
  return 1
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
load_monitors
tick=0

while true; do
  if ! read -r x y < <(cursor_pos); then
    sleep 0.5
    continue
  fi

  # Periodically reconcile with the real bar state (theme reloads can re-hide it)
  # and re-read monitor geometry (outputs may have been added/removed/moved).
  if ((tick % RESYNC_EVERY == 0)); then
    visible=false
    waybar_visible && visible=true
    load_monitors
  fi
  tick=$((tick + 1))

  if [[ -f $PIN_FILE ]]; then
    want=true
  elif $visible; then
    # Keep-while-shown is width-agnostic: only the vertical position matters so
    # the bar doesn't retract while the cursor tracks across it.
    [[ $y -le $KEEP_PX ]] && want=true || want=false
  elif [[ $y -le $REVEAL_PX ]] && in_hot_zone "$x"; then
    want=true
  else
    want=false
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
