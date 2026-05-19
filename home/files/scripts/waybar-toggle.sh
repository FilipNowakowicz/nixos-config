#!/bin/bash

WAYBAR_STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/waybar-toggle/state"

waybar_pids() {
  ps -eo pid=,comm=,args= |
    awk '$2 == ".waybar-wrapped" && $3 == "waybar" { print $1 }
         $2 == "waybar" { print $1 }' |
    sort -n -u
}

waybar_visible() {
  hyprctl layers 2>/dev/null | grep -q 'namespace: waybar'
}

was_visible=false
if waybar_visible; then
  was_visible=true
fi

mkdir -p "$(dirname "$WAYBAR_STATE_FILE")"

while IFS= read -r pid; do
  [[ -n $pid ]] || continue
  kill -USR1 "$pid" 2>/dev/null || true
done < <(waybar_pids)

if [[ $was_visible == true ]]; then
  echo hidden >"$WAYBAR_STATE_FILE"
else
  echo visible >"$WAYBAR_STATE_FILE"
  sleep 0.2
  while IFS= read -r pid; do
    [[ -n $pid ]] || continue
    kill -USR2 "$pid" 2>/dev/null || true
  done < <(waybar_pids)
fi
