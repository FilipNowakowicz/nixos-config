#!/usr/bin/env python3
"""Print Claude Code and Codex usage limits and recent sessions as JSON.

Claude's limits and sessions come from what its status line records under
$XDG_STATE_HOME/agent-usage (see home/files/agents/claude-statusline.sh), and
whether a session is busy from Claude Code's own registry in ~/.claude/sessions.
Codex records its limits, and the plan they belong to, in its own session logs.
Anything missing reports null or an empty list, so the card can say there is
nothing to show.
"""

import base64
import datetime
import json
import os
import pathlib
import re
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
        sessions.append({
            "tool": "claude",
            "id": s.get("id") or path.stem,
            "cwd": cwd,
            "project": os.path.basename((s.get("project") or cwd).rstrip("/")),
            "model": s.get("model") or "",
            "context": s.get("context"),
            "at": int(at),
            "state": {"busy": "working", "idle": "idle"}.get(known.get("status")) or state(now, at),
            "name": known.get("name") or "",
        })
    return {
        "five_hour": window(five.get("used_percentage"), five.get("resets_at"), now),
        "week": window(week.get("used_percentage"), week.get("resets_at"), now),
        "seen": usage.get("at"),
        # The status line hands over limits only for a subscription.
        "paid": None,
    }, sessions


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
    now = time.time() if len(sys.argv) < 2 else float(sys.argv[1])
    home = pathlib.Path(os.environ.get("HOME", "/nonexistent"))
    state_home = pathlib.Path(os.environ.get("XDG_STATE_HOME") or home / ".local/state")
    codex_home = pathlib.Path(os.environ.get("CODEX_HOME") or home / ".codex")
    claude_limits, claude_sessions = claude(state_home / "agent-usage", home / ".claude/sessions", now)
    codex_limits, codex_sessions = codex(codex_home / "sessions", codex_home / "auth.json", now)
    sessions = sorted(claude_sessions + codex_sessions, key=lambda s: -s["at"])
    print(json.dumps({
        "now": int(now),
        "claude": claude_limits,
        "codex": codex_limits,
        "sessions": sessions[:6],
    }))


if __name__ == "__main__":
    main()
