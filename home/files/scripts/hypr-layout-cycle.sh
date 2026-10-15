#!/usr/bin/env bash
# SUPER+M: cycle the tiling layout dwindle -> master -> scrolling -> monocle.
#
# general:layout is global, so this switches every workspace at once. The
# change is runtime-only: a config reload or relogin returns to the default
# set in hyprland.conf.
set -euo pipefail

layouts=(dwindle master scrolling monocle)

current=$(hyprctl getoption general:layout | sed -n 's/^str: //p')

next=${layouts[0]}
for i in "${!layouts[@]}"; do
  if [[ ${layouts[$i]} == "$current" ]]; then
    next=${layouts[$(((i + 1) % ${#layouts[@]}))]}
    break
  fi
done

hyprctl keyword general:layout "$next" >/dev/null
notify-send -t 1200 "Layout" "$next"
