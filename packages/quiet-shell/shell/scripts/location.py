#!/usr/bin/env python3
"""Where the laptop is, for Night mode and the weather: location.py [place].

Without an argument, prints wlsunset's location arguments. With `place`, prints
{"place", "lat", "lon"} as JSON instead.

The town chosen in Spotlight ("location <town>") wins while the clock is still in
its time zone. Otherwise the position is the time zone's main city, which is
offline, private, and follows the machine; an IP lookup would only report the VPN
exit.
"""

import json
import os
import pathlib
import re
import sys


def degrees(text):
    """Convert ISO 6709 +DDMM, +DDMMSS, +DDDMM or +DDDMMSS to decimal degrees."""
    sign = -1 if text[0] == "-" else 1
    digits = text[1:]
    width = 2 + len(digits) % 2
    value = int(digits[:width]) + int(digits[width:width + 2]) / 60
    if len(digits) > width + 2:
        value += int(digits[width + 2:]) / 3600
    return sign * round(value, 2)


def chosen(zone):
    """The town picked in Spotlight, if the clock still follows its zone."""
    default = pathlib.Path.home() / ".local/state/quiet-shell/location.json"
    try:
        place = json.loads(pathlib.Path(os.environ.get("QUIET_LOCATION") or default).read_text())
        if place["zone"] == zone:
            return place["name"], round(float(place["lat"]), 2), round(float(place["lon"]), 2)
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def from_zone(zone):
    """The coordinates tzdata gives the zone's main city."""
    table = pathlib.Path(os.environ["QUIET_ZONE_TAB"])
    for line in table.read_text().splitlines():
        fields = line.split("\t")
        if not line.startswith("#") and len(fields) >= 3 and fields[2] == zone:
            match = re.fullmatch(r"([+-]\d+)([+-]\d+)", fields[1])
            if match:
                return zone.rpartition("/")[2].replace("_", " "), degrees(match.group(1)), degrees(match.group(2))
    return None


zone = os.environ.get("QUIET_TIMEZONE") or os.path.realpath("/etc/localtime").partition("zoneinfo/")[2]
found = chosen(zone) or from_zone(zone)
if not found:
    sys.exit(f"no coordinates for timezone {zone!r}")
name, lat, lon = found
if sys.argv[1:] == ["place"]:
    print(json.dumps({"place": name, "lat": lat, "lon": lon}))
else:
    print("-l", lat, "-L", lon)
