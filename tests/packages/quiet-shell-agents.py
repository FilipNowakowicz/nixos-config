"""Check agents.py against made-up Claude status-line records and Codex logs."""

import base64
import datetime
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
    assert empty["claude"] == {"five_hour": None, "week": None, "seen": None, "paid": None}, empty
    assert empty["codex"] == {"five_hour": None, "week": None, "seen": None, "paid": None}, empty
    assert empty["sessions"] == [], empty

    usage = home / ".local/state/agent-usage"
    (usage / "claude-sessions").mkdir(parents=True)
    # The five-hour window already reset; the week has not.
    (usage / "claude.json").write_text(json.dumps({"at": NOW - 600, "rate_limits": {
        "five_hour": {"used_percentage": 97, "resets_at": NOW - 60},
        "seven_day": {"used_percentage": 41.6, "resets_at": NOW + 3600},
    }}))
    # Session records name the process that runs them; real processes stand in.
    boot = pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip()

    def started(pid):
        return pathlib.Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]

    def record(name, at, **fields):
        path = usage / f"claude-sessions/{name}.json"
        path.write_text(json.dumps({"id": name, **fields}))
        touch(path, at)

    def owned(pid):
        return {"pid": pid, "started": started(pid), "boot": boot}

    sleeper = subprocess.Popen(["sleep", "60"])
    finished = subprocess.Popen(["true"])
    finished.wait()
    me = os.getpid()
    record("a", NOW - 30, cwd="/home/u/nix", project="/home/u/nix", model="Opus", context=12, **owned(me))
    # A resume first reports under a fresh id from the same process; only the newest record counts.
    record("a-phantom", NOW - 600, cwd="/home/u/nix", **owned(me))
    # Idle for longer than Codex sessions are shown, but its process still runs.
    record("b", NOW - 7 * 3600, cwd="/home/u/notes", model="Sonnet", context=None, **owned(sleeper.pid))
    # Closed: the process is gone. Older boot: the pid may be reused. Old format: no process at all.
    record("closed", NOW - 60, cwd="/home/u/old", pid=finished.pid, started="1", boot=boot)
    record("old-boot", NOW - 60, cwd="/home/u/old", pid=me, started=started(me), boot="another-boot")
    record("no-pid", NOW - 60, cwd="/home/u/old")
    (usage / "claude-sessions/broken.json").write_text("{not json")

    # Claude Code's own registry says the long-quiet session is busy after all; an
    # entry for a pid that is gone, or a broken one, changes nothing.
    registry = home / ".claude/sessions"
    registry.mkdir(parents=True)
    (registry / f"{sleeper.pid}.json").write_text(json.dumps(
        {"pid": sleeper.pid, "procStart": started(sleeper.pid), "status": "busy", "name": "notes-7"}))
    (registry / f"{finished.pid}.json").write_text(json.dumps(
        {"pid": finished.pid, "procStart": "1", "status": "busy", "name": "gone"}))
    (registry / "junk.json").write_text("[]")

    # A Codex log from two days ago, with a cut-off last line after the limits.
    day = home / ".codex/sessions/2027/01/13"
    day.mkdir(parents=True)
    log = day / "rollout-x.jsonl"
    log.write_text("\n".join([
        json.dumps({"type": "session_meta", "payload": {"id": "x", "cwd": "/home/u/app"}}),
        json.dumps({"type": "event_msg", "payload": {"rate_limits": {
            "primary": {"used_percent": 19.0, "window_minutes": 300, "resets_at": NOW - 100},
            "secondary": {"used_percent": 12.0, "window_minutes": 10080, "resets_at": NOW + 86400},
            "plan_type": "plus",
        }}}),
        '{"type": "event_msg", "payl',
    ]))
    touch(log, NOW - 2 * 86400)

    got = run(home)
    # The log says plus and nothing newer disagrees.
    assert got["codex"]["paid"] is True, got["codex"]
    assert got["claude"]["paid"] is None, got["claude"]
    assert got["claude"]["five_hour"] == {"used": 0, "resets": None}, got["claude"]
    assert got["claude"]["week"] == {"used": 42, "resets": NOW + 3600}, got["claude"]
    assert got["codex"]["five_hour"] == {"used": 0, "resets": None}, got["codex"]
    assert got["codex"]["week"] == {"used": 12, "resets": NOW + 86400}, got["codex"]
    # Newest first; only running Claude sessions, and not the old Codex log.
    assert [(s["id"], s["state"], s["project"], s["name"]) for s in got["sessions"]] == [
        ("a", "working", "nix", ""),
        ("b", "working", "notes", "notes-7"),
    ], got["sessions"]
    sleeper.kill()

    # A sign-in token refreshed after that session says the subscription ended.
    def signed(plan, refreshed):
        claims = {"https://api.openai.com/auth": {"chatgpt_plan_type": plan}}
        body = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
        stamp = datetime.datetime.fromtimestamp(refreshed, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.123456789Z")
        (home / ".codex/auth.json").write_text(json.dumps({
            "auth_mode": "chatgpt", "last_refresh": stamp, "tokens": {"access_token": f"h.{body}.sig"}}))

    signed("free", NOW - 86400)
    assert run(home)["codex"]["paid"] is False
    # An older token loses to the newer session log.
    signed("free", NOW - 3 * 86400)
    assert run(home)["codex"]["paid"] is True
    # Signed in with an API key instead: no plan to go by, so the log decides.
    (home / ".codex/auth.json").write_text(json.dumps({"auth_mode": "apikey"}))
    assert run(home)["codex"]["paid"] is True

print("quiet-shell agents.py: ok")
