#!/usr/bin/env python3
"""Print Claude Code and Codex usage limits and recent sessions as JSON.

Claude's limits and sessions come from what its status line records under
$XDG_STATE_HOME/agent-usage (see home/files/agents/claude-statusline.sh), and
whether a session is busy from Claude Code's own registry in ~/.claude/sessions.
Codex records its limits, and the plan they belong to, in its own session logs.
Anything missing reports null or an empty list, so the card can say there is
nothing to show.

With --detail, for the agent board, each session also carries what it has been
doing (from its transcript), the bottom of its terminal screen (from kitty), and
Claude's limits a projection of when they run out at the current pace.
"""

import base64
import datetime
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import time

# A session that has spoken in the last few minutes is working; one quiet for
# longer is idle. Codex sessions drop off the list after a few hours quiet;
# Claude sessions are listed while their process runs.
WORKING = 3 * 60
SHOWN = 6 * 3600
# Codex logs can grow large; its latest limits are in the last lines.
TAIL_BYTES = 256 * 1024


def load(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def tail(path, size=TAIL_BYTES):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            end = f.tell()
            f.seek(max(0, end - size))
            lines = f.read().decode(errors="replace").splitlines()
    except OSError:
        return []
    # The first line is likely cut in half unless the whole file was read.
    return lines if end <= size else lines[1:]


def window(used, resets, now):
    """One limit window. Past its reset time it is empty again, whatever was last seen."""
    if used is None:
        return None
    if resets is not None and resets <= now:
        return {"used": 0, "resets": None}
    return {"used": round(float(used)), "resets": int(resets) if resets is not None else None}


def mtime(path):
    try:
        return path.stat().st_mtime
    except OSError:
        return 0


def process_start(pid):
    """Start time of a running process, in clock ticks since boot, or None."""
    try:
        stat = pathlib.Path(f"/proc/{int(pid)}/stat").read_text()
    except (OSError, TypeError, ValueError):
        return None
    # Fields after the parenthesised command name; the start time is field 22.
    return stat.rsplit(")", 1)[1].split()[19]


def boot_id():
    try:
        return pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    except OSError:
        return None


def running(record, boot):
    """The status line names the Claude process that owns a session. Checking its
    start time and the boot keeps a reused pid from reviving a closed session."""
    return (
        boot is not None
        and record.get("boot") == boot
        and record.get("started") is not None
        and process_start(record.get("pid")) == str(record["started"])
    )


def ancestors(pid):
    """A process and every parent above it, nearest first."""
    chain = []
    while isinstance(pid, int) and pid > 1 and pid not in chain:
        chain.append(pid)
        try:
            pid = int(pathlib.Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[1])
        except (OSError, IndexError, ValueError):
            break
    return chain


def kitty_windows(runtime):
    """Every kitty window, from the socket each kitty listens on (see
    home/files/kitty/kitty.conf): its socket, its id, and the processes in it."""
    windows = []
    for sock in sorted(runtime.glob("kitty-*")):
        try:
            if not stat.S_ISSOCK(sock.stat().st_mode):
                continue
            out = subprocess.run(["kitty", "@", "--to", f"unix:{sock}", "ls"],
                                 capture_output=True, text=True, timeout=2)
            listing = json.loads(out.stdout) if out.returncode == 0 else []
        except (OSError, ValueError, subprocess.TimeoutExpired):
            continue
        kitty_pid = sock.name.rsplit("-", 1)[-1]
        for os_window in listing:
            for tab in os_window.get("tabs") or []:
                for w in tab.get("windows") or []:
                    pids = {w.get("pid")} | {f.get("pid") for f in w.get("foreground_processes") or []}
                    windows.append({
                        # One kitty process can own many desktop windows; the
                        # title tells the shell which of them to bring forward.
                        "terminal": {"socket": str(sock), "window": w.get("id"),
                                     "kitty": int(kitty_pid) if kitty_pid.isdigit() else None,
                                     "title": w.get("title") or ""},
                        "pids": {p for p in pids if isinstance(p, int)},
                    })
    return windows


def place(sessions, runtime):
    """Name the kitty window each session runs in, so the shell can type into it."""
    windows = kitty_windows(runtime) if any(s.get("pid") for s in sessions) else []
    for s in sessions:
        chain = ancestors(s.pop("pid", None))
        s["terminal"] = next((w["terminal"] for w in windows if w["pids"] & set(chain)), None)


def state(now, at):
    return "working" if now - at < WORKING else "idle"


def registry(root):
    """Claude Code's own record of each running session, by pid. It says whether the
    session is busy, which beats guessing from how recently the status line ran. It
    is Claude Code's private format, so anything unexpected is simply left out."""
    found = {}
    for path in root.glob("*.json"):
        r = load(path)
        if not isinstance(r, dict) or not isinstance(r.get("pid"), int):
            continue
        if process_start(r["pid"]) != str(r.get("procStart")):
            continue
        found[r["pid"]] = r
    return found


def attention(base, session_id):
    """Why a session waits on the person, as its hooks recorded it
    (home/files/agents/claude-attention.sh), or None."""
    record = load(base / "claude-attention" / f"{session_id}.json")
    return record if isinstance(record, dict) and record.get("kind") else None


def settle(status, waiting, now, at):
    """One state for the board: waiting (an approval or an answer), working,
    done (the turn ended and it is your move) or idle."""
    kind = (waiting or {}).get("kind")
    if kind in ("permission", "question"):
        return "waiting"
    if status == "busy":
        return "working"
    if kind in ("done", "idle"):
        return "done"
    if status == "idle":
        return "idle"
    return state(now, at)


def claude(base, sessions_dir, now):
    usage = load(base / "claude.json") or {}
    limits = usage.get("rate_limits") or {}
    five = limits.get("five_hour") or {}
    week = limits.get("seven_day") or {}
    boot = boot_id()
    # A resumed session first reports under a fresh id, then under the one it
    # resumes; both name the same process, so keep only its newest record.
    newest = {}
    for path in (base / "claude-sessions").glob("*.json"):
        s = load(path)
        if not s or not running(s, boot):
            continue
        at = mtime(path)
        if s["pid"] not in newest or at > newest[s["pid"]][1]:
            newest[s["pid"]] = (s, at, path)
    live = registry(sessions_dir)
    sessions = []
    for s, at, path in newest.values():
        cwd = s.get("cwd") or ""
        known = live.get(s["pid"]) or {}
        sid = s.get("id") or path.stem
        waiting = attention(base, sid)
        sessions.append({
            "tool": "claude",
            "id": sid,
            "cwd": cwd,
            "project": os.path.basename((s.get("project") or cwd).rstrip("/")),
            "model": s.get("model") or "",
            "context": s.get("context"),
            "at": int(at),
            "state": settle(known.get("status"), waiting, now, at),
            "waiting": (waiting or {}).get("message") or "",
            "name": known.get("name") or "",
            "pid": s["pid"],
            "cost": s.get("cost"),
            "lines": s.get("lines"),
            "started": int(known["startedAt"] / 1000) if isinstance(known.get("startedAt"), (int, float)) else None,
            "transcript": s.get("transcript") or "",
        })
    return {
        "five_hour": window(five.get("used_percentage"), five.get("resets_at"), now),
        "week": window(week.get("used_percentage"), week.get("resets_at"), now),
        "seen": usage.get("at"),
        # The status line hands over limits only for a subscription.
        "paid": None,
    }, sessions


def history(path):
    """Claude's limit readings over time, oldest first, as the status line logs them."""
    out = []
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return out
    for line in lines:
        try:
            r = json.loads(line)
            out.append((float(r["at"]), r.get("five"), r.get("week")))
        except (ValueError, KeyError, TypeError):
            continue
    return out


# Too short a stretch says nothing about a pace.
PACE_SPAN = 15 * 60


def runs_out(win, samples, since, now):
    """When a limit window fills at the pace since `since`, if before it resets.
    The pace is the change from the first reading in that stretch to now."""
    if not win or win["resets"] is None:
        return None
    readings = [(at, used) for at, used in samples if used is not None and at >= since]
    if not readings or now - readings[0][0] < PACE_SPAN:
        return None
    first_at, first_used = readings[0]
    rate = (win["used"] - float(first_used)) / (now - first_at)
    if rate <= 0:
        return None
    eta = now + (100 - win["used"]) / rate
    return int(eta) if eta < win["resets"] else None


def project(limits, path, now):
    """Add `runs_out` to Claude's windows: the five-hour one at its pace this
    window, the week at its pace over the last day."""
    samples = history(path)
    five, week = limits["five_hour"], limits["week"]
    if five:
        start = five["resets"] - 5 * 3600 if five["resets"] else now
        five["runs_out"] = runs_out(five, [(a, f) for a, f, _ in samples], start, now)
    if week:
        start = max(now - 86400, week["resets"] - 7 * 86400 if week["resets"] else now)
        week["runs_out"] = runs_out(week, [(a, w) for a, _, w in samples], start, now)


# The board shows a handful of each.
FEED_ITEMS = 60
# A reply longer than this is cut; the terminal has the rest.
SAID_CHARS = 6000
SCREEN_LINES = 18


def brief(tool, args):
    """One line for a tool call: what it ran or touched."""
    if not isinstance(args, dict):
        return tool
    for key in ("description", "command", "file_path", "pattern", "url", "query", "prompt", "path"):
        value = args.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip().splitlines()[0][:160]
    return ""


def said(content):
    """The person's own words in a user message, leaving out tool results and the
    tags Claude Code wraps around commands and reminders."""
    if isinstance(content, str):
        parts = [content]
    elif isinstance(content, list):
        parts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
    else:
        return ""
    words = [p.strip() for p in parts if p.strip() and not p.lstrip().startswith("<")]
    return "\n".join(words)


def activity(path):
    """The end of a session's conversation, from its transcript, as a feed to read
    on the board: your prompts, what it wrote (whole, as Markdown), and its tool
    calls in one line each; plus your last prompt and its git branch."""
    found = {"prompt": "", "feed": [], "branch": ""}
    if not path:
        return found
    feed = []
    for line in tail(pathlib.Path(path), 768 * 1024):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict) or entry.get("isSidechain"):
            continue
        if entry.get("gitBranch"):
            found["branch"] = entry["gitBranch"]
        message = entry.get("message") or {}
        if entry.get("type") == "user" and not entry.get("isMeta"):
            words = said(message.get("content"))
            if words:
                found["prompt"] = words[:400]
                feed.append({"kind": "you", "text": words[:SAID_CHARS]})
        elif entry.get("type") == "assistant" and isinstance(message.get("content"), list):
            for c in message["content"]:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "tool_use":
                    feed.append({"kind": "tool", "name": c.get("name") or "", "text": brief(c.get("name"), c.get("input"))})
                elif c.get("type") == "text" and c.get("text", "").strip():
                    feed.append({"kind": "said", "text": c["text"].strip()[:SAID_CHARS]})
    found["feed"] = feed[-FEED_ITEMS:]
    return found


def screen(terminal):
    """The bottom of a session's terminal, as kitty shows it: where a permission
    prompt or a question waits."""
    if not terminal:
        return ""
    try:
        out = subprocess.run(
            ["kitty", "@", "--to", f"unix:{terminal['socket']}", "get-text",
             "--match", f"id:{terminal['window']}", "--extent", "screen"],
            capture_output=True, text=True, timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if out.returncode != 0:
        return ""
    lines = [l.rstrip() for l in out.stdout.splitlines()]
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines[-SCREEN_LINES:])


def codex_logs(root, now):
    """Session logs from the last week, newest first: the weekly limit outlives a quiet spell."""
    days = []
    for offset in range(8):
        day = datetime.date.fromtimestamp(now) - datetime.timedelta(days=offset)
        days.append(root / f"{day:%Y}" / f"{day:%m}" / f"{day:%d}")
    logs = [p for d in days for p in d.glob("*.jsonl")]
    return sorted(logs, key=mtime, reverse=True)


def stamp(text):
    """An ISO time as Codex writes it, nanoseconds and all."""
    try:
        text = re.sub(r"(\.\d{6})\d+", r"\1", text).replace("Z", "+00:00")
        return datetime.datetime.fromisoformat(text).timestamp()
    except (AttributeError, TypeError, ValueError):
        return None


def signed_plan(auth_path):
    """The plan named in Codex's sign-in token, and when the token was refreshed.
    Only its claims are read, from the file Codex keeps; nothing is verified or
    sent anywhere, and the token itself goes no further than this function."""
    auth = load(auth_path)
    if not isinstance(auth, dict) or auth.get("auth_mode") != "chatgpt":
        return None, None
    try:
        part = auth["tokens"]["access_token"].split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
        plan = claims["https://api.openai.com/auth"]["chatgpt_plan_type"]
    except (AttributeError, IndexError, KeyError, TypeError, ValueError):
        return None, None
    return plan, stamp(auth.get("last_refresh")) or mtime(auth_path)


def codex(root, auth_path, now):
    limits = None
    seen = None
    sessions = []
    for path in codex_logs(root, now):
        at = mtime(path)
        if limits is None:
            lines = tail(path)
            for line in reversed(lines):
                if '"rate_limits"' not in line:
                    continue
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                found = _find(record, "rate_limits")
                if found:
                    limits = found
                    seen = int(at)
                    break
        if now - at <= SHOWN:
            meta = {}
            try:
                with open(path) as f:
                    first = json.loads(f.readline())
                if first.get("type") == "session_meta":
                    meta = first.get("payload") or {}
            except (OSError, ValueError):
                pass
            cwd = meta.get("cwd") or ""
            sessions.append({
                "tool": "codex",
                "id": meta.get("id") or path.stem,
                "cwd": cwd,
                "project": os.path.basename(cwd.rstrip("/")),
                "model": meta.get("model") or "",
                "context": None,
                "at": int(at),
                "state": state(now, at),
            })
        elif limits is not None:
            break
    limits = limits or {}
    # A session log names the plan its limits belong to, but only as of that
    # session. The sign-in token is refreshed between sessions, so the newer of
    # the two says whether there is a subscription now.
    plan, plan_at = limits.get("plan_type"), seen
    signed, signed_at = signed_plan(auth_path)
    if signed is not None and (plan is None or signed_at > (plan_at or 0)):
        plan = signed
    primary = limits.get("primary") or {}
    secondary = limits.get("secondary") or {}
    return {
        "five_hour": window(primary.get("used_percent"), primary.get("resets_at"), now),
        "week": window(secondary.get("used_percent"), secondary.get("resets_at"), now),
        "seen": seen,
        "paid": None if plan is None else plan != "free",
    }, sessions


def _find(value, key):
    """The first value stored under `key` anywhere in a parsed record."""
    if isinstance(value, dict):
        if isinstance(value.get(key), dict):
            return value[key]
        for v in value.values():
            found = _find(v, key)
            if found:
                return found
    elif isinstance(value, list):
        for v in value:
            found = _find(v, key)
            if found:
                return found
    return None


def main():
    args = [a for a in sys.argv[1:] if a != "--detail"]
    detail = "--detail" in sys.argv[1:]
    now = time.time() if not args else float(args[0])
    home = pathlib.Path(os.environ.get("HOME", "/nonexistent"))
    state_home = pathlib.Path(os.environ.get("XDG_STATE_HOME") or home / ".local/state")
    codex_home = pathlib.Path(os.environ.get("CODEX_HOME") or home / ".codex")
    claude_limits, claude_sessions = claude(state_home / "agent-usage", home / ".claude/sessions", now)
    codex_limits, codex_sessions = codex(codex_home / "sessions", codex_home / "auth.json", now)
    sessions = sorted(claude_sessions + codex_sessions, key=lambda s: -s["at"])[:6]
    runtime = pathlib.Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}")
    place(sessions, runtime)
    for s in sessions:
        transcript = s.pop("transcript", "")
        if detail:
            s.update(activity(transcript))
            # The screen matters where the transcript can't say it: a prompt's
            # choices while it waits, or a session with no transcript to read.
            s["screen"] = screen(s["terminal"]) if s["state"] == "waiting" or not s["feed"] else ""
    if detail:
        project(claude_limits, state_home / "agent-usage/claude-history.jsonl", now)
    print(json.dumps({
        "now": int(now),
        "claude": claude_limits,
        "codex": codex_limits,
        "sessions": sessions,
    }))


if __name__ == "__main__":
    main()
