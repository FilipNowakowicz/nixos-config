#!/usr/bin/env bash
# SUPER+M: cycle the tiling layout dwindle -> master -> scrolling -> monocle.
#
# general:layout is global, so this switches every workspace at once. The
# change is runtime-only: a config reload or relogin returns to the default
# set in hyprland.lua.
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

reply=$(hyprctl eval "hl.config({general={layout='$next'}})")
[[ $reply == ok ]] || {
  echo "$reply" >&2
  exit 1
}
[[ $(hyprctl getoption general:layout | sed -n 's/^str: //p') == "$next" ]] || exit 1
notify-send -t 1200 "Layout" "$next"
