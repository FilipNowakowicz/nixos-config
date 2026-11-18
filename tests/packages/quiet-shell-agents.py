"""Check agents.py against made-up Claude status-line records and Codex logs."""

import base64
import datetime
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile

script = sys.argv[1]
NOW = 1_800_000_000


def run(home, *flags):
    # Its own runtime directory, so the real kitty windows here are never asked.
    runtime = home / "runtime"
    runtime.mkdir(exist_ok=True)
    env = {"HOME": str(home), "XDG_RUNTIME_DIR": str(runtime),
           "PATH": f"{home / 'bin'}:{os.environ.get('PATH', '')}"}
    out = subprocess.run([sys.executable, script, *flags, str(NOW)], env=env, capture_output=True, text=True, check=True)
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
    # No kitty listening yet, so nothing to type into.
    assert [s["terminal"] for s in got["sessions"]] == [None, None], got["sessions"]
    assert all("pid" not in s for s in got["sessions"]), got["sessions"]

    # A kitty whose window runs this test, so the sleeper it started is inside it.
    # Another socket's kitty fails; a plain file named like a socket is not asked.
    runtime = home / "runtime"
    listening = socket.socket(socket.AF_UNIX)
    listening.bind(str(runtime / "kitty-4242"))
    broken = socket.socket(socket.AF_UNIX)
    broken.bind(str(runtime / "kitty-5151"))
    (runtime / "kitty-99").write_text("")
    (home / "bin").mkdir()
    fake = home / "bin/kitty"
    fake.write_text(f"""#!{sys.executable}
import json, sys
to = sys.argv[sys.argv.index("--to") + 1]
assert "kitty-99" not in to, to
if to.endswith("kitty-5151"):
    sys.exit(1)
if "get-text" in sys.argv:
    assert sys.argv[sys.argv.index("--match") + 1] == "id:7", sys.argv
    print("\\n".join(["old line"] * 30 + ["Do you want to proceed?", "  1. Yes", "  2. No", "", ""]))
    sys.exit(0)
print(json.dumps([{{"tabs": [{{"windows": [
    {{"id": 1, "pid": 1, "foreground_processes": []}},
    {{"id": 7, "pid": {os.getppid()}, "title": "claude", "foreground_processes": [{{"pid": {os.getpid()}}}]}},
]}}]}}]))
""")
    fake.chmod(0o755)
    got = run(home)
    # Session a's process is this test itself, b's is its child: both are in window 7.
    assert [s["terminal"] for s in got["sessions"]] == [
        {"socket": str(runtime / "kitty-4242"), "window": 7, "kitty": 4242, "title": "claude"}] * 2, got["sessions"]

    # The board's detail: attention from the hooks, activity from the transcript,
    # the bottom of the screen from kitty, and when the limits run out.
    attention = usage / "claude-attention"
    attention.mkdir()
    (attention / "b.json").write_text(json.dumps({"at": NOW, "kind": "permission", "message": "Claude needs your permission to use Bash"}))
    (attention / "a.json").write_text(json.dumps({"at": NOW, "kind": "done", "message": ""}))
    transcript = home / "a.jsonl"
    transcript.write_text("\n".join(json.dumps(e) for e in [
        {"type": "user", "gitBranch": "main", "message": {"role": "user", "content": "first ask"}},
        {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Read", "input": {"file_path": "/old"}}]}},
        {"type": "user", "gitBranch": "board", "message": {"content": [{"type": "text", "text": "<system-reminder>x</system-reminder>"}, {"type": "text", "text": "build the board"}]}},
        {"type": "user", "isMeta": True, "message": {"content": "meta, not said"}},
        {"type": "user", "message": {"content": [{"type": "tool_result", "content": "ok"}]}},
        {"type": "assistant", "message": {"content": [
            {"type": "text", "text": "Starting with the hook."},
            {"type": "tool_use", "name": "Bash", "input": {"command": "nix build .#x\nsecond line", "description": "Build it"}},
            {"type": "tool_use", "name": "Edit", "input": {"file_path": "/repo/agents.py"}},
        ]}},
        {"type": "assistant", "isSidechain": True, "message": {"content": [{"type": "text", "text": "a subagent"}]}},
    ]) + "\n{broken")
    record("a", NOW - 30, cwd="/home/u/nix", project="/home/u/nix", model="Opus", context=12,
           cost=1.5, transcript=str(transcript), **owned(me))
    (usage / "claude.json").write_text(json.dumps({"at": NOW, "rate_limits": {
        "five_hour": {"used_percentage": 50, "resets_at": NOW + 3 * 3600},
        "seven_day": {"used_percentage": 42, "resets_at": NOW + 3600},
    }}))
    # Readings from before this five-hour window and this last day don't count.
    (usage / "claude-history.jsonl").write_text("\n".join(json.dumps(r) for r in [
        {"at": NOW - 2 * 86400, "five": 1, "week": 1},
        {"at": NOW - 4 * 3600, "five": 10, "week": 30},
        {"at": NOW - 2 * 3600, "five": 30, "week": 42},
        "not a record",
    ]))
    plain = run(home)
    assert "prompt" not in plain["sessions"][0] and "runs_out" not in plain["claude"]["week"], plain
    assert [s["state"] for s in plain["sessions"]] == ["done", "waiting"], plain["sessions"]
    assert plain["sessions"][1]["waiting"] == "Claude needs your permission to use Bash", plain["sessions"]

    got = run(home, "--detail")
    a = got["sessions"][0]
    assert a["prompt"] == "build the board", a
    assert a["branch"] == "board", a
    # The conversation in order: prompts in your own words, what it wrote, and
    # tool calls as one line; not reminders, meta entries, tool results or subagents.
    assert a["feed"] == [
        {"kind": "you", "text": "first ask"},
        {"kind": "tool", "name": "Read", "text": "/old"},
        {"kind": "you", "text": "build the board"},
        {"kind": "said", "text": "Starting with the hook."},
        {"kind": "tool", "name": "Bash", "text": "Build it"},
        {"kind": "tool", "name": "Edit", "text": "/repo/agents.py"},
    ], a["feed"]
    assert a["cost"] == 1.5, a
    # Its transcript says it all, so its screen isn't read...
    assert a["screen"] == "", a
    # ...but b waits on a prompt, and has no transcript: the bottom of its screen.
    b = got["sessions"][1]
    assert b["feed"] == [] and b["state"] == "waiting", b
    assert b["screen"].splitlines()[-3:] == ["Do you want to proceed?", "  1. Yes", "  2. No"], b["screen"]
    assert len(b["screen"].splitlines()) == 18, b["screen"]
    # Started 2h ago at 30%, now 50: 10 an hour, so 100 in 5h, past the reset in 3h.
    assert got["claude"]["five_hour"]["runs_out"] is None, got["claude"]
    # From 10 two hours ago to 50 now is 20 an hour: full in 2.5h, before the reset.
    (usage / "claude-history.jsonl").write_text(json.dumps({"at": NOW - 2 * 3600, "five": 10, "week": 41}))
    got = run(home, "--detail")
    assert got["claude"]["five_hour"]["runs_out"] == NOW + int(50 / 20 * 3600), got["claude"]
    # The week rose one point in two hours: 58 more takes far longer than its hour.
    assert got["claude"]["week"]["runs_out"] is None, got["claude"]
    # A reading only minutes old says nothing about the pace.
    (usage / "claude-history.jsonl").write_text(json.dumps({"at": NOW - 300, "five": 10, "week": 41}))
    assert run(home, "--detail")["claude"]["five_hour"]["runs_out"] is None

    listening.close()
    broken.close()
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
