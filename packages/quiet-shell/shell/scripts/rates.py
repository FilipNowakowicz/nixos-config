#!/usr/bin/env python3
"""Print exchange rates against the euro as JSON, or nothing if none are known.

Rates are the European Central Bank's daily reference rates, through Frankfurter,
which needs no key. They change once a working day, so a copy is kept for twelve
hours, and an older copy is still better than nothing when offline.
"""

import json
import os
import pathlib
import subprocess
import sys
import time

state = pathlib.Path(os.environ.get("XDG_STATE_HOME") or pathlib.Path.home() / ".local/state") / "quiet-shell"
cache = state / "rates.json"
FRESH = 12 * 3600


def cached():
    try:
        return json.loads(cache.read_text())
    except (OSError, ValueError):
        return None


def fetch():
    try:
        out = subprocess.run(
            ["curl", "-sf", "--max-time", "8", "https://api.frankfurter.dev/v1/latest?base=EUR"],
            capture_output=True, text=True, timeout=10, check=False,
        )
        data = json.loads(out.stdout)
        rates = {code: float(rate) for code, rate in data["rates"].items()}
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError, AttributeError):
        return None
    rates["EUR"] = 1.0
    return {"date": str(data.get("date", "")), "rates": rates}


old = cached()
fresh = old is not None and time.time() - cache.stat().st_mtime < FRESH
if not fresh:
    new = fetch()
    if new:
        state.mkdir(parents=True, exist_ok=True)
        tmp = cache.with_suffix(".tmp")
        tmp.write_text(json.dumps(new))
        tmp.replace(cache)
        old = new
if old:
    json.dump(old, sys.stdout)
