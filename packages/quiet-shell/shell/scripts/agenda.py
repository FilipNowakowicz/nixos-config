#!/usr/bin/env python3
"""Print this month's events and the weeks after it as JSON, or nothing on failure.

This reads what vdirsyncer last saved, through khal, so it works offline and the
shell never sees a feed's address. Dates are ISO because home/profiles/calendar.nix
sets khal's locale that way.
"""

import datetime
import json
import subprocess
import sys

FIELDS = ["title", "location", "start-date", "start-time", "end-date", "end-time"]

today = datetime.date.today()
first = today.replace(day=1)
next_month = (first + datetime.timedelta(days=32)).replace(day=1)
# The grid needs the whole month, and "Up next" still needs events at the end of it.
last = max(next_month - datetime.timedelta(days=1), today + datetime.timedelta(days=21))

command = ["khal", "list", first.isoformat(), last.isoformat(), "-df", ""]
for field in FIELDS:
    command += ["--json", field]
try:
    out = subprocess.run(command, capture_output=True, text=True, timeout=20, check=True).stdout
except (OSError, subprocess.SubprocessError):
    sys.exit(0)

# khal repeats an event on every day it covers. Its --once flag would also collapse
# the separate dates of a recurring event, so drop only exact repeats.
events = {}
try:
    for line in filter(str.strip, out.splitlines()):
        for event in json.loads(line):
            entry = {
                "title": event["title"],
                "location": event["location"],
                "day": event["start-date"],
                "until": event["end-date"],
                "start": event["start-time"],
                "end": event["end-time"],
            }
            events[tuple(entry.values())] = entry
except (ValueError, KeyError, TypeError):
    sys.exit(0)
print(json.dumps(sorted(events.values(), key=lambda e: (e["day"], e["start"]))))
