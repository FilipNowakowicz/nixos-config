#!/usr/bin/env python3
"""Resume Claude sessions that a usage limit stopped, once that limit resets.

A user timer runs this every minute. It only acts on sessions switched on in the
overview's agents card, which leaves an empty file per Claude process under
$XDG_STATE_HOME/agent-usage/resume (see agents.py). A session is resumed when
the last turn in its transcript is the record Claude Code writes in place of a
reply when a limit is hit, the time that record names has passed, Claude Code's
registry says the session is idle, and nothing is typed on its prompt. A long
conversation is compacted first. Text goes in through the kitty window the
session runs in, as a paste followed by Enter, so it reads as if typed.

This is a plain script rather than an agent: anything driven by the same
account would be stopped by the same limit.
"""

import os
import pathlib
import re
import subprocess
import sys
import time

import agents

MESSAGE = "The usage limit has reset. Carry on from where you stopped."
# Above this share of the context window, compact before carrying on.
COMPACT_AT = 50
# Resets are stamped to the minute; give the server's clock a moment.
MARGIN = 60
# How long a compaction may take before giving up on carrying on.
COMPACT_WAIT = 15 * 60

KINDS = {"five_hour": "5-hour", "seven_day": "weekly"}
# A horizontal rule. Claude Code writes a named session's name into the top one
# ("──── name ─"), so a rule may carry one label of text between its runs.
RULE = re.compile(r"^(?=.*─{8})─+(?: \S(?:.*\S)? ─+)?$")
SGR = re.compile(r"(\x1b\[[0-9;:]*m)")


def log(*parts):
    print(*parts, flush=True)


def note(usage, key, name, why):
    """Logs why a switched-on session is left alone, once each time the reason
    changes, so a quiet night can be told apart from one the watcher missed."""
    seen = usage / "resume-why" / key
    try:
        if seen.read_text() == why:
            return
    except OSError:
        pass
    seen.parent.mkdir(parents=True, exist_ok=True)
    seen.write_text(why)
    log(f"{name}: {why}")


def kitty(terminal, *args, text=None):
    return subprocess.run(
        ["kitty", "@", "--to", f"unix:{terminal['socket']}", *args, "--match", f"id:{terminal['window']}"],
        input=text, capture_output=True, text=True, timeout=10)


def typed(line):
    """What the user typed on one line of the prompt: text in the terminal's own
    colour. Claude Code draws its marker, hints and suggestions in other colours."""
    plain, dim, out = True, False, []
    for piece in SGR.split(line):
        if not SGR.fullmatch(piece):
            if plain and not dim:
                out.append(piece)
            continue
        params = piece[2:-1].split(";") if piece[2:-1] else ["0"]
        i = 0
        while i < len(params):
            p = params[i]
            head = p.split(":")[0]
            if head in ("", "0"):
                plain, dim = True, False
            elif head == "2":
                dim = True
            elif head == "22":
                dim = False
            elif head == "39":
                plain = True
            elif re.fullmatch(r"3[0-7]|9[0-7]|38", head):
                plain = False
            # An extended colour written with semicolons carries its own parameters.
            if head in ("38", "48", "58") and ":" not in p and i + 1 < len(params):
                i += {"5": 2, "2": 4}.get(params[i + 1], 0)
            i += 1
    return "".join(out).replace("\xa0", " ").strip()


def prompt_empty(screen):
    """Whether the input box at the bottom of Claude Code's screen holds nothing.
    The box sits between the last two horizontal rules; a screen without one is
    showing something else, a question or a menu, and does not count as empty."""
    lines = screen.splitlines()
    rules = [i for i, line in enumerate(lines) if RULE.match(SGR.sub("", line).strip())]
    if len(rules) < 2:
        return False
    top, bottom = rules[-2], rules[-1]
    box = lines[top + 1:bottom]
    if not box or not SGR.sub("", box[0]).lstrip().startswith("❯"):
        return False
    # The marker is not always drawn in its own colour, so it never counts.
    first = typed(box[0])
    first = first[1:].strip() if first.startswith("❯") else first
    return first == "" and all(typed(line) == "" for line in box[1:])


def send(terminal, text, pause=time.sleep):
    """Type text into the session's terminal as a paste, then press Enter. Claude
    Code drops an Enter that comes before it has taken the paste in, so wait for
    the text to show on the prompt first, and press again if it is still there."""
    pasted = kitty(terminal, "send-text", "--bracketed-paste", "auto", "--stdin", text=text)
    if pasted.returncode != 0:
        return False
    for _ in range(15):
        if not prompt_empty(screen(terminal)):
            break
        pause(0.2)
    for _ in range(3):
        if kitty(terminal, "send-key", "enter").returncode != 0:
            return False
        pause(0.5)
        if prompt_empty(screen(terminal)):
            return True
    return False


def screen(terminal):
    out = kitty(terminal, "get-text", "--ansi")
    return out.stdout if out.returncode == 0 else ""


def wait_compacted(path, after, deadline, clock, pause):
    """Wait for the compaction to land in the transcript after the limit record.
    A fresh limit, or running out of time, ends the wait without it."""
    while clock() < deadline:
        later, seen = [], False
        for r in agents.records(path):
            if seen:
                later.append(r)
            seen = seen or r.get("uuid") == after
        if any(r.get("type") == "system" and r.get("subtype") == "compact_boundary" for r in later):
            return True
        if any(r.get("error") == "rate_limit" for r in later):
            return False
        pause(5)
    return False


def context_of(usage, pid, started):
    """The context share the status line last saw for this process."""
    best, at = None, -1
    for path in (usage / "claude-sessions").glob("*.json"):
        s = agents.load(path)
        if not isinstance(s, dict) or s.get("pid") != pid or str(s.get("started")) != str(started):
            continue
        if agents.mtime(path) > at:
            best, at = s.get("context"), agents.mtime(path)
    return best if isinstance(best, (int, float)) else None


def run(home, state_home, runtime, now, clock=time.time, pause=time.sleep):
    usage = state_home / "agent-usage"
    armed_dir = usage / "resume"
    done_dir = usage / "resumed"
    live = agents.registry(home / ".claude/sessions")
    windows = None
    for armed in sorted(armed_dir.glob("*")) if armed_dir.is_dir() else []:
        pid, _, started = armed.name.partition("-")
        done = done_dir / armed.name
        if not pid.isdigit() or agents.process_start(int(pid)) != started:
            # The session's process is gone; its switch goes with it.
            armed.unlink(missing_ok=True)
            done.unlink(missing_ok=True)
            (usage / "resume-why" / armed.name).unlink(missing_ok=True)
            continue
        pid = int(pid)
        session = live.get(pid) or {}
        name = session.get("name") or armed.name
        path = agents.transcript(home / ".claude/projects", session.get("sessionId"))
        limit = agents.stopped(path)
        if not limit:
            note(usage, armed.name, name, "not stopped by a usage limit")
            continue
        try:
            if done.read_text().strip() == limit["uuid"]:
                continue
        except OSError:
            pass
        if now < limit["resets"] + MARGIN:
            at = time.strftime("%H:%M", time.localtime(limit["resets"]))
            note(usage, armed.name, name, f"waiting for the limit to reset at {at}")
            continue
        if session.get("status") != "idle":
            note(usage, armed.name, name, f"limit reset, but the session is {session.get('status') or 'not registered'}")
            continue
        if windows is None:
            windows = agents.kitty_windows(runtime)
        chain = set(agents.ancestors(pid))
        terminal = next((w["terminal"] for w in windows if w["pids"] & chain), None)
        if terminal is None:
            log(f"{name}: no kitty window to type into")
            continue
        if not prompt_empty(screen(terminal)):
            log(f"{name}: something is on the prompt; trying again in a minute")
            continue
        # Recorded first, so a failure below never types the same thing twice.
        done_dir.mkdir(parents=True, exist_ok=True)
        done.write_text(limit["uuid"] + "\n")
        context = context_of(usage, pid, started)
        if context is not None and context >= COMPACT_AT:
            log(f"{name}: {KINDS.get(limit['kind'], 'usage')} limit reset; compacting at {round(context)}% context")
            if not send(terminal, "/compact", pause):
                log(f"{name}: could not type into its terminal")
                continue
            if not wait_compacted(path, limit["uuid"], clock() + COMPACT_WAIT, clock, pause):
                log(f"{name}: compaction did not finish; leaving it be")
                continue
            # The prompt comes back once Claude Code is idle again.
            deadline = clock() + 60
            while clock() < deadline:
                if (agents.registry(home / ".claude/sessions").get(pid) or {}).get("status") == "idle" \
                        and prompt_empty(screen(terminal)):
                    break
                pause(2)
            else:
                log(f"{name}: did not come back after compacting; leaving it be")
                continue
        log(f"{name}: {KINDS.get(limit['kind'], 'usage')} limit reset; resuming")
        if not send(terminal, MESSAGE, pause):
            log(f"{name}: could not type into its terminal")


def main():
    now = time.time() if len(sys.argv) < 2 else float(sys.argv[1])
    home = pathlib.Path(os.environ.get("HOME", "/nonexistent"))
    state_home = pathlib.Path(os.environ.get("XDG_STATE_HOME") or home / ".local/state")
    runtime = pathlib.Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}")
    run(home, state_home, runtime, now)


if __name__ == "__main__":
    main()
