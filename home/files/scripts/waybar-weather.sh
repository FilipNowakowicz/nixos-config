#!/bin/bash
# wttr.in's %c format emits a full-color emoji glyph that ignores waybar's CSS
# `color`, so it always renders in its own fixed color (e.g. a yellow sun)
# regardless of theme. Use the textual condition (%C) instead and map it to a
# monochrome Nerd Font "Weather Icons" glyph, which is a normal font codepoint
# and inherits #custom-weather's `color` like every other status icon.
set -uo pipefail

result=$(curl -sf --max-time 5 "wttr.in/Warsaw?format=%C|%t")
if [ -z "$result" ]; then
  echo "? --"
  exit 0
fi

condition="${result%%|*}"
temp="${result#*|}"
condition_lower=$(printf '%s' "$condition" | tr '[:upper:]' '[:lower:]')

hour=$(date +%-H)
is_day=1
if [ "$hour" -lt 6 ] || [ "$hour" -ge 20 ]; then
  is_day=0
fi

case "$condition_lower" in
*thunder*) icon=$'' ;;                     # weather-thunderstorm
*snow* | *sleet* | *ice*) icon=$'' ;;      # weather-snow
*rain* | *drizzle* | *shower*) icon=$'' ;; # weather-rain
*fog* | *mist* | *haze*) icon=$'' ;;       # weather-fog
*overcast* | *cloud*) icon=$'' ;;          # weather-cloudy
*sun* | *clear*)
  if [ "$is_day" -eq 1 ]; then
    icon=$'' # weather-day_sunny
  else
    icon=$'' # weather-night_clear
  fi
  ;;
*) icon=$'' ;; # weather-na
esac

echo "$icon $temp"
