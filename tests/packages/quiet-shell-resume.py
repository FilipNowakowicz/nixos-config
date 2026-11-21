"""Check resume.py against a made-up Claude session and a fake kitty that records
what is typed into it, and stands in for Claude when asked to compact."""

import importlib.util
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile

script = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(script.parent))
spec = importlib.util.spec_from_file_location("resume", script)
resume = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resume)

NOW = 1_800_000_000
RULE = "─" * 40


def screen(prompt):
    """The bottom of Claude Code's screen, styled as kitty's get-text --ansi gives it."""
    return (f"\x1b[m● Done.\n\x1b[38:2:136:136:136m{RULE}\x1b[39m\n"
            f"\x1b[m\x1b[38:2:153:153:153m❯\xa0{prompt}\n"
            f"\x1b[38:2:136:136:136m{RULE}\x1b[39m\n  Opus | ~/nix | ctx:12%\n")


# Only text in the terminal's own colour counts as typed.
assert resume.prompt_empty(screen(" "))
assert resume.prompt_empty(screen("\x1b[2mTry \"fix the tests\"\x1b[22m"))
assert resume.prompt_empty(screen("\x1b[38;2;90;90;90msuggestion\x1b[0m"))
assert not resume.prompt_empty(screen("\x1b[39mhalf a thought"))
# Claude Code sometimes draws its marker in the terminal's own colour.
plain = f"{RULE}\n\x1b[m❯\xa0\n{RULE}\n  status\n"
assert resume.prompt_empty(plain)
assert not resume.prompt_empty(plain.replace("❯\xa0", "❯\xa0half a thought"))
assert not resume.prompt_empty(screen("\x1b[38;5;8mhint \x1b[0mtyped"))
# A named session carries its name in the top rule, as `claude -n` draws it.
named = f"{RULE} trading batch 2 ─\n\x1b[m❯\xa0\n{RULE}\n  status\n"
assert resume.prompt_empty(named)
assert not resume.prompt_empty(named.replace("❯\xa0", "❯\xa0half a thought"))
# A permission question or any other screen has no input box to judge.
assert not resume.prompt_empty("Do you want to proceed?\n❯ 1. Yes\n  2. No\n")


def started(pid):
    return pathlib.Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]


with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    home, state, runtime = root / "home", root / "state", root / "runtime"
    for d in (home / ".claude/sessions", home / ".claude/projects/-home-u-nix",
              state / "agent-usage/claude-sessions", runtime, root / "bin"):
        d.mkdir(parents=True)
    log = home / ".claude/projects/-home-u-nix/sess.jsonl"
    sent = root / "sent.jsonl"
    shown = root / "screen.txt"
    pending = root / "pending.txt"
    drop = root / "drop"

    # A kitty whose window 7 runs this test, and so the session it stands for.
    fake = root / "bin/kitty"
    fake.write_text(f"""#!{sys.executable}
import json, sys
args = sys.argv[1:]
if "ls" in args:
    print(json.dumps([{{"tabs": [{{"windows": [
        {{"id": 7, "pid": {os.getppid()}, "title": "claude", "foreground_processes": [{{"pid": {os.getpid()}}}]}}]}}]}}]))
elif "get-text" in args:
    import os
    shown = open({str(shown)!r}).read()
    if os.path.exists({str(pending)!r}):
        shown = shown.replace("❯\\xa0 ", "❯\\xa0\\x1b[39m" + open({str(pending)!r}).read())
    print(shown, end="")
elif "send-text" in args:
    text = sys.stdin.read()
    with open({str(sent)!r}, "a") as f:
        f.write(json.dumps(text) + "\\n")
    # The paste shows on the prompt until Enter takes it.
    with open({str(pending)!r}, "w") as f:
        f.write(text)
    # Claude compacts when asked to, unless this test says it hangs.
    if text == "/compact" and not __import__("os").path.exists({str(root / "hang")!r}):
        with open({str(log)!r}, "a") as f:
            f.write(json.dumps({{"type": "system", "subtype": "compact_boundary"}}) + "\\n")
elif "send-key" in args:
    import os
    with open({str(sent)!r}, "a") as f:
        f.write(json.dumps("<enter>") + "\\n")
    # Claude Code drops an Enter now and then; this test says when.
    if os.path.exists({str(drop)!r}):
        os.unlink({str(drop)!r})
    elif os.path.exists({str(pending)!r}):
        os.unlink({str(pending)!r})
""")
    fake.chmod(0o755)
    os.environ["PATH"] = f"{root / 'bin'}:{os.environ.get('PATH', '')}"
    # Only a real socket counts as a kitty listening.
    listening = socket.socket(socket.AF_UNIX)
    listening.bind(str(runtime / "kitty-4242"))

    me = os.getpid()
    key = f"{me}-{started(me)}"
    usage = state / "agent-usage"

    def registry(status):
        (home / ".claude/sessions" / f"{me}.json").write_text(json.dumps(
            {"pid": me, "procStart": started(me), "status": status, "sessionId": "sess", "name": "nix-1"}))

    def transcript(*lines):
        log.write_text("".join(json.dumps(r) + "\n" for r in lines))

    def limit(uuid, resets=NOW - 120):
        return {"type": "assistant", "uuid": uuid, "error": "rate_limit",
                "apiErrorParams": {"rate_limit_info": {"resetsAt": resets, "rateLimitType": "five_hour"}}}

    def context(share):
        (usage / "claude-sessions/sess.json").write_text(json.dumps(
            {"id": "sess", "pid": me, "started": started(me), "context": share}))

    class Clock:
        def __init__(self):
            self.t = 0.0

        def __call__(self):
            return self.t

        def pause(self, seconds):
            self.t += seconds

    def tick(now=NOW):
        sent.unlink(missing_ok=True)
        clock = Clock()
        resume.run(home, state, runtime, now, clock=clock, pause=clock.pause)
        return [json.loads(line) for line in sent.read_text().splitlines()] if sent.exists() else []

    registry("idle")
    transcript({"type": "user", "uuid": "u1"}, limit("l1"), {"type": "system", "subtype": "turn_duration"})
    shown.write_text(screen(" "))
    context(12)

    # Not switched on: left alone.
    assert tick() == []
    (usage / "resume").mkdir()
    (usage / "resume" / key).touch()
    # Switched on, but the limit has not reset yet, or only just.
    assert tick(NOW - 600) == []
    assert tick(NOW - 120 + 30) == []
    # Busy, or a half-typed message on the prompt: wait.
    registry("busy")
    assert tick() == []
    registry("idle")
    shown.write_text(screen("\x1b[39mhalf a thought"))
    assert tick() == []
    shown.write_text(screen(" "))
    # Due: carries on, once per limit.
    assert tick() == [resume.MESSAGE, "<enter>"]
    assert (usage / "resumed" / key).read_text().strip() == "l1"
    assert not pending.exists()
    assert tick() == []
    # The session moved on and hit a limit again later; a background task then
    # finished while it was stopped, which Claude Code files as a prompt.
    notice = {"type": "user", "uuid": "n1", "origin": {"kind": "task-notification"}}
    meta = {"type": "user", "uuid": "n2", "isMeta": True}
    transcript({"type": "user", "uuid": "u1"}, limit("l1"), {"type": "user", "uuid": "u2"}, limit("l2"), meta, notice)
    # The first Enter is dropped, as Claude Code does when it comes too soon.
    drop.touch()
    assert tick() == [resume.MESSAGE, "<enter>", "<enter>"]
    assert not pending.exists()
    # A prompt from a person is the session moving on.
    transcript(limit("l2b"), {"type": "user", "uuid": "u2b", "origin": {"kind": "human"}})
    assert tick() == []
    assert (usage / "resume-why" / key).read_text() == "not stopped by a usage limit"

    # A long conversation is compacted first.
    context(73)
    transcript({"type": "user", "uuid": "u3"}, limit("l3"))
    assert tick() == ["/compact", "<enter>", resume.MESSAGE, "<enter>"]
    # A compaction that never lands leaves the session alone after it.
    (root / "hang").touch()
    transcript({"type": "user", "uuid": "u4"}, limit("l4"))
    assert tick() == ["/compact", "<enter>"]
    assert tick() == []

    # A switch left by a process that is gone is cleared.
    finished = subprocess.Popen(["true"])
    finished.wait()
    (usage / "resume" / f"{finished.pid}-1").touch()
    (usage / "resumed" / f"{finished.pid}-1").write_text("old\n")
    tick()
    assert not (usage / "resume" / f"{finished.pid}-1").exists()
    assert not (usage / "resumed" / f"{finished.pid}-1").exists()
    assert (usage / "resume" / key).exists()
    listening.close()

print("quiet-shell resume.py: ok")
