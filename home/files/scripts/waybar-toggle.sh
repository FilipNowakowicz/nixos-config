#!/bin/bash

WAYBAR_PENDING_RELOAD="${XDG_STATE_HOME:-$HOME/.local/state}/waybar/needs-reload"

waybar_pids() {
  ps -eo pid=,comm=,args= |
    awk '$2 == ".waybar-wrapped" && $3 == "waybar" { print $1 }
         $2 == "waybar" { print $1 }' |
    sort -n -u
}

waybar_visible() {
  # Visible at layer level 2 ("top"); SIGUSR1 drops it to level 1 ("bottom").
  hyprctl layers 2>/dev/null | awk '
    /^[[:space:]]*Layer level 2/  { in_top = 1; next }
    /^[[:space:]]*Layer level/    { in_top = 0; next }
    in_top && /namespace: waybar/ { found = 1; exit }
    END { exit !found }
  '
}

was_visible=false
if waybar_visible; then
  was_visible=true
fi

while IFS= read -r pid; do
  [[ -n $pid ]] || continue
  kill -USR1 "$pid" 2>/dev/null || true
done < <(waybar_pids)

# Only reload on un-hide if a theme switch happened while the bar was hidden.
# Unconditional SIGUSR2 here causes a visible jump on every toggle because
# waybar tears down and rebuilds the bar surface even when nothing changed.
if [[ $was_visible == false && -f $WAYBAR_PENDING_RELOAD ]]; then
  sleep 0.2
  while IFS= read -r pid; do
    [[ -n $pid ]] || continue
    kill -USR2 "$pid" 2>/dev/null || true
  done < <(waybar_pids)
  rm -f "$WAYBAR_PENDING_RELOAD"
fi
