"""Check agents.py against made-up Claude status-line records and Codex logs."""

import json
import os
import pathlib
import subprocess
import sys
import tempfile

script = sys.argv[1]
NOW = 1_800_000_000


def run(home):
    env = {"HOME": str(home), "PATH": os.environ.get("PATH", "")}
    out = subprocess.run([sys.executable, script, str(NOW)], env=env, capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def touch(path, at):
    os.utime(path, (at, at))


with tempfile.TemporaryDirectory() as tmp:
    home = pathlib.Path(tmp)

    # Nothing recorded yet: every limit is null and nothing is running.
    empty = run(home)
    assert empty["claude"] == {"five_hour": None, "week": None, "seen": None}, empty
    assert empty["codex"] == {"five_hour": None, "week": None, "seen": None}, empty
    assert empty["sessions"] == [], empty

    usage = home / ".local/state/agent-usage"
    (usage / "claude-sessions").mkdir(parents=True)
    # The five-hour window already reset; the week has not.
    (usage / "claude.json").write_text(json.dumps({"at": NOW - 600, "rate_limits": {
        "five_hour": {"used_percentage": 97, "resets_at": NOW - 60},
        "seven_day": {"used_percentage": 41.6, "resets_at": NOW + 3600},
    }}))
    working = usage / "claude-sessions/a.json"
    working.write_text(json.dumps({"id": "a", "cwd": "/home/u/nix", "project": "/home/u/nix", "model": "Opus", "context": 12}))
    touch(working, NOW - 30)
    idle = usage / "claude-sessions/b.json"
    idle.write_text(json.dumps({"id": "b", "cwd": "/home/u/notes", "model": "Sonnet", "context": None}))
    touch(idle, NOW - 1800)
    stale = usage / "claude-sessions/c.json"
    stale.write_text(json.dumps({"id": "c", "cwd": "/home/u/old"}))
    touch(stale, NOW - 7 * 3600)
    (usage / "claude-sessions/broken.json").write_text("{not json")

    # A Codex log from two days ago, with a cut-off last line after the limits.
    day = home / ".codex/sessions/2027/01/13"
    day.mkdir(parents=True)
    log = day / "rollout-x.jsonl"
    log.write_text("\n".join([
        json.dumps({"type": "session_meta", "payload": {"id": "x", "cwd": "/home/u/app"}}),
        json.dumps({"type": "event_msg", "payload": {"rate_limits": {
            "primary": {"used_percent": 19.0, "window_minutes": 300, "resets_at": NOW - 100},
            "secondary": {"used_percent": 12.0, "window_minutes": 10080, "resets_at": NOW + 86400},
        }}}),
        '{"type": "event_msg", "payl',
    ]))
    touch(log, NOW - 2 * 86400)

    got = run(home)
    assert got["claude"]["five_hour"] == {"used": 0, "resets": None}, got["claude"]
    assert got["claude"]["week"] == {"used": 42, "resets": NOW + 3600}, got["claude"]
    assert got["codex"]["five_hour"] == {"used": 0, "resets": None}, got["codex"]
    assert got["codex"]["week"] == {"used": 12, "resets": NOW + 86400}, got["codex"]
    # Newest first; the seven-hour-old session and the old Codex log are not listed.
    assert [(s["id"], s["state"], s["project"]) for s in got["sessions"]] == [
        ("a", "working", "nix"),
        ("b", "idle", "notes"),
    ], got["sessions"]

print("quiet-shell agents.py: ok")
