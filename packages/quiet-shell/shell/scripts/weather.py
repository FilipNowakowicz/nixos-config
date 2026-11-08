#!/usr/bin/env python3
"""Print the current weather and the next few forecasts as JSON, or nothing on failure.

The position comes from location.py, like Night mode: the town chosen in Spotlight,
or else the time zone's main city. The VPN never moves the forecast.
"""

import datetime
import json
import pathlib
import subprocess
import sys

here = pathlib.Path(__file__).parent
located = subprocess.run([sys.executable, str(here / "location.py"), "place"], capture_output=True, text=True, check=False)
try:
    where = json.loads(located.stdout)
except ValueError:
    sys.exit(0)
url = f"https://wttr.in/{where['lat']},{where['lon']}?format=j1"
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
        "place": where["place"],
        "condition": condition(current),
        "temperature": current["temp_C"] + "°",
        "hours": upcoming(data["weather"]),
    }))
except (ValueError, KeyError, IndexError, TypeError):
    sys.exit(0)
