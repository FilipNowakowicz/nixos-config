#!/usr/bin/env bash
# SUPER+M: cycle the tiling layout dwindle -> master -> scrolling -> monocle.
#
# general:layout is global, so this switches every workspace at once. The
# change is runtime-only: a config reload or relogin returns to the default
# set in hyprland.lua.
set -euo pipefail

# Probe the running parser, not the installed package or config filenames.
# During a rebuild the old compositor can outlive the package/config switch.
lua_config=false
if [[ $(hyprctl eval 'assert(type(hl) == "table")' 2>/dev/null) == ok ]]; then
  lua_config=true
fi

layouts=(dwindle master scrolling monocle)

current=$(hyprctl getoption general:layout | sed -n 's/^str: //p')

next=${layouts[0]}
for i in "${!layouts[@]}"; do
  if [[ ${layouts[$i]} == "$current" ]]; then
    next=${layouts[$(((i + 1) % ${#layouts[@]}))]}
    break
  fi
done

if $lua_config; then
  reply=$(hyprctl eval "hl.config({general={layout='$next'}})")
else
  reply=$(hyprctl keyword general:layout "$next")
fi
[[ $reply == ok ]] || {
  echo "$reply" >&2
  exit 1
}
[[ $(hyprctl getoption general:layout | sed -n 's/^str: //p') == "$next" ]] || exit 1
notify-send -t 1200 "Layout" "$next"
