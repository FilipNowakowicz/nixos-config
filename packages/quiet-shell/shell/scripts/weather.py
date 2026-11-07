#!/usr/bin/env python3
"""Print the current weather and the next few forecasts as JSON, or nothing on failure.

The position comes from the timezone, like Night mode, so the laptop doesn't need
a stored location, and the VPN doesn't move the forecast.
"""

import datetime
import json
import os
import pathlib
import subprocess
import sys

here = pathlib.Path(__file__).parent
where = subprocess.run([sys.executable, str(here / "location.py")], capture_output=True, text=True, check=False).stdout.split()
if len(where) != 4:
    sys.exit(0)
zone = os.environ.get("QUIET_TIMEZONE") or os.path.realpath("/etc/localtime").partition("zoneinfo/")[2]
url = f"https://wttr.in/{where[1]},{where[3]}?format=j1"
try:
    out = subprocess.run(["curl", "-sf", "--max-time", "8", url], capture_output=True, text=True, timeout=10, check=False)
except (OSError, subprocess.TimeoutExpired):
    sys.exit(0)


def condition(entry):
    return entry["weatherDesc"][0]["value"].strip()


# Forecasts come every three hours, in the place's local time, which is the laptop's.
def upcoming(days, count=5):
    now = datetime.datetime.now()
    slots = []
    for day in days:
        for slot in day["hourly"]:
            at = datetime.datetime.fromisoformat(day["date"]) + datetime.timedelta(hours=int(slot["time"]) // 100)
            if at > now:
                slots.append({"time": at.strftime("%H:%M"), "condition": condition(slot), "temperature": slot["tempC"] + "°"})
    return slots[:count]


try:
    data = json.loads(out.stdout)
    current = data["current_condition"][0]
    print(json.dumps({
        "place": zone.rpartition("/")[2].replace("_", " "),
        "condition": condition(current),
        "temperature": current["temp_C"] + "°",
        "hours": upcoming(data["weather"]),
    }))
except (ValueError, KeyError, IndexError, TypeError):
    sys.exit(0)
