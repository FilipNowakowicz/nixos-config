#!/usr/bin/env python3
"""Print the current weather as JSON, or nothing if it can't be fetched.

The position comes from the timezone, like Night mode, so the laptop doesn't need
a stored location, and the VPN doesn't move the forecast.
"""

import json
import os
import pathlib
import subprocess
import sys
import urllib.parse

here = pathlib.Path(__file__).parent
where = subprocess.run([sys.executable, str(here / "location.py")], capture_output=True, text=True, check=False).stdout.split()
if len(where) != 4:
    sys.exit(0)
zone = os.environ.get("QUIET_TIMEZONE") or os.path.realpath("/etc/localtime").partition("zoneinfo/")[2]
url = f"https://wttr.in/{where[1]},{where[3]}?format=" + urllib.parse.quote("%C|%t")
try:
    out = subprocess.run(["curl", "-sf", "--max-time", "5", url], capture_output=True, text=True, timeout=7, check=False)
except (OSError, subprocess.TimeoutExpired):
    sys.exit(0)
condition, _, temperature = out.stdout.strip().partition("|")
if out.returncode != 0 or not temperature:
    sys.exit(0)
print(json.dumps({
    "place": zone.rpartition("/")[2].replace("_", " "),
    "condition": condition,
    "temperature": temperature.lstrip("+").replace("°C", "°"),
}))
