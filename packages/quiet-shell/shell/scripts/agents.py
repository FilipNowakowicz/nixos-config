#!/usr/bin/env python3
"""Print Claude Code and Codex usage limits and recent sessions as JSON.

Claude's limits and sessions come from what its status line records under
$XDG_STATE_HOME/agent-usage (see home/files/agents/claude-statusline.sh). Codex
records its limits in its own session logs. Anything missing reports null or an
empty list, so the card can say there is nothing to show.
"""

import datetime
import json
import os
import pathlib
import sys
import time

# A session that has spoken in the last few minutes is working; one quiet for
# longer is idle, and after a few hours it is gone from the list.
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


def state(now, at):
    return "working" if now - at < WORKING else "idle"


def claude(base, now):
    usage = load(base / "claude.json") or {}
    limits = usage.get("rate_limits") or {}
    five = limits.get("five_hour") or {}
    week = limits.get("seven_day") or {}
    sessions = []
    for path in (base / "claude-sessions").glob("*.json"):
        s = load(path)
        at = mtime(path)
        if not s or now - at > SHOWN:
            continue
        cwd = s.get("cwd") or ""
        sessions.append({
            "tool": "claude",
            "id": s.get("id") or path.stem,
            "cwd": cwd,
            "project": os.path.basename((s.get("project") or cwd).rstrip("/")),
            "model": s.get("model") or "",
            "context": s.get("context"),
            "at": int(at),
            "state": state(now, at),
        })
    return {
        "five_hour": window(five.get("used_percentage"), five.get("resets_at"), now),
        "week": window(week.get("used_percentage"), week.get("resets_at"), now),
        "seen": usage.get("at"),
    }, sessions


def codex_logs(root, now):
    """Session logs from the last week, newest first: the weekly limit outlives a quiet spell."""
    days = []
    for offset in range(8):
        day = datetime.date.fromtimestamp(now) - datetime.timedelta(days=offset)
        days.append(root / f"{day:%Y}" / f"{day:%m}" / f"{day:%d}")
    logs = [p for d in days for p in d.glob("*.jsonl")]
    return sorted(logs, key=mtime, reverse=True)


def codex(root, now):
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
    primary = limits.get("primary") or {}
    secondary = limits.get("secondary") or {}
    return {
        "five_hour": window(primary.get("used_percent"), primary.get("resets_at"), now),
        "week": window(secondary.get("used_percent"), secondary.get("resets_at"), now),
        "seen": seen,
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
    claude_limits, claude_sessions = claude(state_home / "agent-usage", now)
    codex_limits, codex_sessions = codex(codex_home / "sessions", now)
    sessions = sorted(claude_sessions + codex_sessions, key=lambda s: -s["at"])
    print(json.dumps({
        "now": int(now),
        "claude": claude_limits,
        "codex": codex_limits,
        "sessions": sessions[:6],
    }))


if __name__ == "__main__":
    main()
