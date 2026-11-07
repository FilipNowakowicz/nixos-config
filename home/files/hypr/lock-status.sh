#!/usr/bin/env bash
# What the lock screen shows. Prints nothing when there is nothing to say.
# Media is deliberately absent: a locked screen shouldn't tell passers-by
# what was playing.

case ${1:-} in
battery)
  # Only worth a glance when it is low or charging.
  for battery in "${QUIET_POWER_SUPPLY:-/sys/class/power_supply}"/BAT*; do
    [[ -r $battery/capacity ]] || continue
    capacity=$(<"$battery/capacity")
    if [[ $(<"$battery/status") == Charging ]]; then
      echo "$capacity% · Charging"
    elif ((capacity <= 20)); then
      echo "$capacity%"
    fi
    break
  done
  ;;
esac
