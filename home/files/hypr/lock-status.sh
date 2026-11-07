#!/usr/bin/env bash
# What the lock screen shows. Prints nothing when there is nothing to say.
# hyprlock reads this as Pango markup, so song titles have to be escaped.
markup() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

case ${1:-} in
media)
  status=$(playerctl status 2>/dev/null) || exit 0
  [[ $status == Playing || $status == Paused ]] || exit 0
  title=$(playerctl metadata title 2>/dev/null) || exit 0
  artist=$(playerctl metadata artist 2>/dev/null) || artist=
  printf '%s\n' "${artist:+$artist — }$title" | markup
  ;;
battery)
  for battery in "${QUIET_POWER_SUPPLY:-/sys/class/power_supply}"/BAT*; do
    [[ -r $battery/capacity ]] || continue
    if [[ $(<"$battery/status") == Charging ]]; then
      echo "$(<"$battery/capacity")% · Charging"
    else
      echo "$(<"$battery/capacity")%"
    fi
    break
  done
  ;;
esac
