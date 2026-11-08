#!/bin/sh
# touchpad.sh true|false: turn every touchpad on or off for this Hyprland session.
hyprctl devices -j |
  python3 -c 'import json, sys; print(*[m["name"] for m in json.load(sys.stdin)["mice"] if "touchpad" in m["name"]], sep="\n")' |
  while read -r device; do
    hyprctl eval "hl.device({name='$device', enabled=$1})" >/dev/null
  done
