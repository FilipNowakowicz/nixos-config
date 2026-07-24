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
# Reveal hot-zone, sized to the VISIBLE pill rather than the whole bar surface.
# The waybar surface spans the full output width, but only the centred
# modules-center box (style.css min-width: 720px) holds content, and that box's
# modules are left-packed — so the painted pill occupies just the left
# BAR_PILL_W px of the box and the rest is transparent slack. Anchoring the
# hot-zone to the pill (box-left .. box-left+BAR_PILL_W), not the full box, stops
# the bar revealing when the cursor is over the invisible slack. Tune BAR_PILL_W
# if the module set (workspaces/clock/battery/custom/sep2/weather) changes; the
# keep-while-shown check stays width-agnostic so the bar never retracts
# mid-use.
# Re-measured 2026-07-23 against a running session (custom/sep2 + weather
# appended): a screenshot put the rightmost rendered glyph at ~511px from the
# box's left edge; hovering the literal tail of the weather text at that
# offset failed to reveal the bar under the old BAR_PILL_W=500, confirming the
# undershoot. 540 clears the measured content with a small buffer.
BAR_BOX_W=720  # modules-center box width (centred per output)
BAR_PILL_W=540 # painted pill width within that box, measured from the box's left edge
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
    awk '$2 == ".waybar-wrapped" && $3 ~ /(^|\/)waybar$/ { print $1 }
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

# True when global cursor x falls over the visible pill on whatever monitor it
# currently sits over. The pill's left edge is the centred box's left edge; its
# right edge is one pill-width further in (not the full box), so the transparent
# slack on the right of the box doesn't trigger a reveal.
in_hot_zone() {
  local cx=$1 i mx mw box_w left right
  for i in "${!MON_X[@]}"; do
    mx=${MON_X[i]}
    mw=${MON_W[i]}
    ((cx >= mx && cx < mx + mw)) || continue
    box_w=$BAR_BOX_W
    ((box_w > mw)) && box_w=$mw
    left=$((mx + (mw - box_w) / 2))
    right=$((left + BAR_PILL_W))
    ((right > mx + mw)) && right=$((mx + mw))
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
