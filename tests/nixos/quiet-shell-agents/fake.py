"""Stands in for scripts/agents.py in the smoke VM: prints sessions.json (copied to
/tmp/agents.json by the test) with its times, given in seconds from now, made
absolute; without that file, nothing is running."""

import json
import pathlib
import time

TIMES = {"at", "since", "asked", "started", "resets", "runs_out", "limited", "seen"}
now = int(time.time())


def shift(value, key=None):
    if isinstance(value, dict):
        return {k: shift(v, k) for k, v in value.items()}
    if isinstance(value, list):
        return [shift(v) for v in value]
    if key in TIMES and isinstance(value, int) and value != 0:
        return now + value
    return value


try:
    data = json.loads(pathlib.Path("/tmp/agents.json").read_text())
except (OSError, ValueError):
    data = {"claude": {"five_hour": None, "week": None, "seen": None, "paid": None},
            "codex": {"five_hour": None, "week": None, "seen": None, "paid": None},
            "sessions": []}
data["now"] = now
print(json.dumps(shift(data)))
