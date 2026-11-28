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
    out = subprocess.run([sys.executable, script, str(NOW), *flags], env=env, capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def plain(limits):
    """A tool's limits without the run-out projections, checked on their own."""
    return {k: ({w: v for w, v in win.items() if w != "runs_out"} if isinstance(win, dict) else win)
            for k, win in limits.items()}


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
    assert plain(got["claude"])["five_hour"] == {"used": 0, "resets": None}, got["claude"]
    assert plain(got["claude"])["week"] == {"used": 42, "resets": NOW + 3600}, got["claude"]
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
    listening.close()
    broken.close()

    # A usage limit ended a's last turn, and a is switched on to resume; b was
    # stopped by one too but carried on since. Only the transcript's end counts.
    projects = home / ".claude/projects"

    def transcript(project, sid, lines):
        d = projects / project
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{sid}.jsonl").write_text("\n".join(json.dumps(r) for r in lines) + "\n")

    def limit(uuid, resets):
        return {"type": "assistant", "uuid": uuid, "error": "rate_limit", "isApiErrorMessage": True,
                "apiErrorParams": {"rate_limit_info": {"resetsAt": resets, "rateLimitType": "five_hour"}}}

    (registry / f"{me}.json").write_text(json.dumps(
        {"pid": me, "procStart": started(me), "status": "idle", "sessionId": "sess-a"}))
    (registry / f"{sleeper.pid}.json").write_text(json.dumps(
        {"pid": sleeper.pid, "procStart": started(sleeper.pid), "status": "idle", "sessionId": "sess-b"}))
    transcript("-home-u-nix", "sess-a", [
        {"type": "user", "uuid": "u1"}, limit("l1", NOW + 3600),
        {"type": "system", "subtype": "turn_duration"}, {"type": "file-history-snapshot"}])
    transcript("-home-u-notes", "sess-b", [limit("l0", NOW - 600), {"type": "user", "uuid": "u2"}])
    key = f"{me}-{started(me)}"
    (usage / "resume").mkdir()
    (usage / "resume" / key).touch()
    by = {s["id"]: s for s in run(home)["sessions"]}
    assert (by["a"]["limited"], by["a"]["resume"], by["a"]["key"]) == (NOW + 3600, True, key), by["a"]
    assert (by["b"]["limited"], by["b"]["resume"]) == (None, False), by["b"]
    # Past its reset, a limit still on the transcript's end reads as due now.
    transcript("-home-u-nix", "sess-a", [{"type": "user", "uuid": "u1"}, limit("l1", NOW - 30)])
    assert {s["id"]: s for s in run(home)["sessions"]}["a"]["limited"] == 0

    # What a session is doing, from its transcript: the person's prompt (not a
    # reminder, a tool result or a subagent's record), its last words, its tool
    # calls, how full its context is, and a tool call still running.
    def at(seconds):
        return datetime.datetime.fromtimestamp(NOW + seconds, datetime.timezone.utc).isoformat().replace("+00:00", "Z")

    def tool(name, args, when):
        return {"type": "assistant", "timestamp": at(when), "message": {"content": [
            {"type": "tool_use", "name": name, "input": args}],
            "usage": {"input_tokens": 2, "cache_read_input_tokens": 90000, "cache_creation_input_tokens": 8}}}

    transcript("-home-u-nix", "sess-a", [
        {"type": "ai-title", "aiTitle": "First idea"},
        {"type": "user", "timestamp": at(-300), "gitBranch": "work", "message": {"content": "Tidy the **bar** up"}},
        {"type": "user", "isMeta": True, "message": {"content": "a reminder"}},
        {"type": "user", "isSidechain": True, "message": {"content": "a subagent's prompt"}},
        {"type": "assistant", "timestamp": at(-250), "message": {"content": [{"type": "text", "text": "## Plan\nLooking at `Top.qml` first."}]}},
        tool("Read", {"file_path": "/home/u/nix/shell/Top.qml"}, -200),
        {"type": "user", "message": {"content": [{"type": "tool_result", "content": "..."}]}},
        tool("Bash", {"command": "nix build .#main-ci\nmore"}, -20),
        {"type": "ai-title", "aiTitle": "Tidy the bar"},
    ])
    # Claude Code's placeholder name gives way to the transcript's title; it waits on you.
    (registry / f"{me}.json").write_text(json.dumps(
        {"pid": me, "procStart": started(me), "status": "waiting", "waitingFor": "dialog open",
         "sessionId": "sess-a", "name": "nix-9d", "nameSource": "derived", "statusUpdatedAt": (NOW - 15) * 1000}))
    # Its subagents: one running, one finished a moment ago, one finished long ago.
    subs = projects / "-home-u-nix/sess-a/subagents"
    subs.mkdir(parents=True)
    for name, meta, when in [("agent-run", {"description": "Build it", "agentType": "general-purpose", "finished": False}, -10),
                             ("agent-done", {"description": "Look around", "agentType": "Explore", "finished": True}, -60),
                             ("agent-old", {"description": "Long gone", "finished": True}, -3600)]:
        (subs / f"{name}.meta.json").write_text(json.dumps(meta))
        (subs / f"{name}.jsonl").write_text(json.dumps(
            {**tool("Grep", {"pattern": "Icon {"}, when), "isSidechain": True}) + "\n")
        touch(subs / f"{name}.meta.json", NOW + when)
        touch(subs / f"{name}.jsonl", NOW + when)
    a = {s["id"]: s for s in run(home)["sessions"]}["a"]
    assert (a["name"], a["state"], a["waiting"], a["since"]) == ("Tidy the bar", "waiting", "dialog open", NOW - 15), a
    assert (a["prompt"], a["said"], a["branch"], a["steps"]) == ("Tidy the bar up", "Looking at Top.qml first.", "work", 2), a
    assert a["doing"] == {"at": NOW - 20, "tool": "Bash", "kind": "run", "text": "nix build .#main-ci"}, a["doing"]
    assert [r["text"] for r in a["recent"]] == ["shell/Top.qml", "nix build .#main-ci"], a["recent"]
    assert a["tokens"] == 90010, a
    assert [(x["id"], x["state"], x["title"]) for x in a["subagents"]] == [
        ("agent-run", "working", "Build it"), ("agent-done", "done", "Look around")], a["subagents"]
    assert a["subagents"][0]["doing"]["text"] == "Icon {", a["subagents"][0]
    # Waiting on you sorts first; the brief answer has no transcript in it.
    assert run(home)["sessions"][0]["id"] == "a"
    quick = {s["id"]: s for s in run(home, "--brief")["sessions"]}["a"]
    assert quick["state"] == "waiting" and "doing" not in quick and quick["subagents"] == [], quick
    # A name a person chose stays.
    (registry / f"{me}.json").write_text(json.dumps(
        {"pid": me, "procStart": started(me), "status": "busy", "sessionId": "sess-a", "name": "mine", "nameSource": "user"}))
    assert {s["id"]: s for s in run(home)["sessions"]}["a"]["name"] == "mine"

    # A background job its state file calls done is finished, though its process lives on.
    (registry / f"{sleeper.pid}.json").write_text(json.dumps(
        {"pid": sleeper.pid, "procStart": started(sleeper.pid), "status": "idle", "sessionId": "sess-b",
         "kind": "bg", "jobId": "job1", "statusUpdatedAt": (NOW - 60) * 1000}))
    (home / ".claude/jobs/job1").mkdir(parents=True)
    (home / ".claude/jobs/job1/state.json").write_text(json.dumps(
        {"state": "done", "detail": "**merged** the PR\nmore", "fan": [{"kind": "shell", "label": "sleep 600", "doneAt": 1}], "tokens": 5}))
    b = {s["id"]: s for s in run(home)["sessions"]}["b"]
    assert (b["state"], b["background"], b["job"]) == ("done", True, {"state": "done", "detail": "merged the PR", "tasks": [], "tokens": 5}), b
    sleeper.kill()

    # The status line's limit history: 20% of the five-hour window in the last
    # hour leaves 58% to go, which at that pace runs out before the reset.
    (usage / "claude.json").write_text(json.dumps({"at": NOW, "rate_limits": {
        "five_hour": {"used_percentage": 42, "resets_at": NOW + 4 * 3600},
        "seven_day": {"used_percentage": 50, "resets_at": NOW + 3 * 86400}}}))
    (usage / "claude-history.jsonl").write_text("\n".join(json.dumps(r) for r in [
        {"at": NOW - 3600, "five": 22, "week": 50}, {"at": NOW - 1800, "five": 32, "week": 50}, "junk"]) + "\n")
    limits = run(home)["claude"]
    assert limits["five_hour"]["runs_out"] == NOW + int(58 / (20 / 3600)), limits
    assert limits["week"]["runs_out"] is None, limits

    # A sign-in token refreshed after that session says the subscription ended.
    def signed(plan, refreshed):
        claims = {"https://api.openai.com/auth": {"chatgpt_plan_type": plan}}
        body = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
        stamp = datetime.datetime.fromtimestamp(refreshed, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.123456789Z")
        (home / ".codex/auth.json").write_text(json.dumps({
            "auth_mode": "chatgpt", "last_refresh": stamp, "tokens": {"access_token": f"h.{body}.sig"}}))

    # A Codex session's own account: its title, the command it ran, and its context.
    (home / ".codex/session_index.jsonl").write_text(json.dumps({"id": "y", "thread_name": "Review the CV"}) + "\n")
    today = home / f".codex/sessions/{datetime.date.fromtimestamp(NOW):%Y/%m/%d}"
    today.mkdir(parents=True)
    log = today / "rollout-y.jsonl"
    log.write_text("\n".join(json.dumps(r) for r in [
        {"type": "session_meta", "payload": {"id": "y", "cwd": "/home/u/cv"}},
        {"type": "event_msg", "payload": {"type": "task_started"}},
        {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"text": "Check the page"}]}},
        {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "exec",
                                              "input": "text(await tools.exec_command({cmd:`pdftoppm cv.pdf page`}))"}},
        {"type": "event_msg", "payload": {"type": "token_count", "info": {
            "last_token_usage": {"input_tokens": 51680}, "model_context_window": 258400}}},
    ]) + "\n")
    touch(log, NOW - 30)
    y = {s["id"]: s for s in run(home)["sessions"]}["y"]
    assert (y["name"], y["state"], y["prompt"], y["context"]) == ("Review the CV", "working", "Check the page", 20), y
    assert y["doing"]["text"] == "pdftoppm cv.pdf page" and y["doing"]["kind"] == "run", y["doing"]

    signed("free", NOW - 86400)
    assert run(home)["codex"]["paid"] is False
    # An older token loses to the newer session log.
    signed("free", NOW - 3 * 86400)
    assert run(home)["codex"]["paid"] is True
    # Signed in with an API key instead: no plan to go by, so the log decides.
    (home / ".codex/auth.json").write_text(json.dumps({"auth_mode": "apikey"}))
    assert run(home)["codex"]["paid"] is True

print("quiet-shell agents.py: ok")
