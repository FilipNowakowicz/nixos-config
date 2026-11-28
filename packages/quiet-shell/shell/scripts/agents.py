#!/usr/bin/env python3
"""Print Claude Code and Codex usage limits and running sessions as JSON.

Claude's limits and sessions come from what its status line records under
$XDG_STATE_HOME/agent-usage (see home/files/agents/claude-statusline.sh), and
each session's state (busy, idle, or waiting on the person and why) from Claude
Code's own registry in ~/.claude/sessions. Its transcript adds a title, what it
is doing now, the subagents it has running and how full its context is; a
background job's own state file says whether it has finished. Whether a usage
limit stopped a session comes from the end of its transcript, and whether to
resume it then (see resume.py) from a file the card leaves per process.
Codex records its limits, plan, tool calls and context in its own session logs.
Anything missing reports null or an empty list, so the card can say there is
nothing to show.

`--brief` leaves out what costs more than a glance (transcripts and terminals),
for the bar's indicator, which asks while nothing else is open.
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
# A background job idle this long has finished, whatever its state file says.
JOB_DONE = 3600
# Subagents: a running one quiet this long has most likely died with its
# parent's turn; a finished one stays on show for a moment.
SUB_STALE = 30 * 60
SUB_DONE = 5 * 60
# Codex logs and transcripts can grow large; what is wanted is at the end.
TAIL_BYTES = 256 * 1024
SUB_TAIL = 64 * 1024
RECENT = 8
SHOWN_SESSIONS = 8


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
    session is busy, idle or waiting on the person, which beats guessing from how
    recently the status line ran. It is Claude Code's private format, so anything
    unexpected is simply left out."""
    found = {}
    for path in root.glob("*.json"):
        r = load(path)
        if not isinstance(r, dict) or not isinstance(r.get("pid"), int):
            continue
        if process_start(r["pid"]) != str(r.get("procStart")):
            continue
        found[r["pid"]] = r
    return found


def transcript(projects, session_id):
    """A session's transcript, under whichever project directory Claude Code chose."""
    if not isinstance(session_id, str) or not re.fullmatch(r"[A-Za-z0-9-]+", session_id):
        return None
    return next(iter(sorted(projects.glob(f"*/{session_id}.jsonl"))), None)


def records(path, size=TAIL_BYTES):
    """The transcript's last records, oldest first; a line that does not parse is skipped."""
    found = []
    for line in tail(path, size) if path else []:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict):
            found.append(r)
    return found


def automatic(record):
    """A prompt Claude Code wrote itself rather than one a person sent."""
    origin = record.get("origin")
    kind = origin.get("kind") if isinstance(origin, dict) else None
    return record.get("type") == "user" and bool(record.get("isMeta") or kind not in (None, "human"))


def stopped(entries):
    """The usage limit that ended a session's last turn, if one did: the record
    Claude Code writes in place of a reply, its id, and when the limit resets. A
    later reply, or a later prompt from a person, means the session has moved on
    since. Notices Claude Code files on its own, such as a background task
    finishing, arrive as prompts too but go unanswered while the limit lasts."""
    for r in reversed(entries):
        if r.get("isSidechain") or r.get("type") not in ("user", "assistant") or automatic(r):
            continue
        if r.get("type") != "assistant" or r.get("error") != "rate_limit":
            return None
        info = (r.get("apiErrorParams") or {}).get("rate_limit_info") or r.get("quotaLimits") or {}
        resets = info.get("resetsAt")
        if not isinstance(resets, (int, float)) or not r.get("uuid"):
            return None
        return {"uuid": r["uuid"], "resets": int(resets), "kind": info.get("rateLimitType") or ""}
    return None


def process_key(pid, started):
    """Names one run of a process; the card's resume switch is a file by this name."""
    return f"{pid}-{started}"


# What a tool call says about what an agent is doing, for the card's wording
# (and its little faces). Anything else is "tool".
KINDS = {
    "read": {"Read", "Grep", "Glob", "LS", "NotebookRead", "ToolSearch"},
    "edit": {"Edit", "Write", "MultiEdit", "NotebookEdit"},
    "run": {"Bash", "BashOutput", "KillShell", "Monitor", "TaskStop", "exec", "exec_command",
            "shell", "local_shell", "write_stdin"},
    "web": {"WebSearch", "WebFetch", "web_search"},
    "delegate": {"Agent", "Task", "SendMessage"},
    "plan": {"TodoWrite", "EnterPlanMode", "ExitPlanMode", "update_plan"},
    "ask": {"AskUserQuestion"},
    "skill": {"Skill"},
}


def kind_of(tool):
    for kind, names in KINDS.items():
        if tool in names:
            return kind
    if isinstance(tool, str) and "browser" in tool.lower():
        return "web"
    return "tool"


def brief(tool, args):
    """One line for a tool call: what it ran or touched."""
    if not isinstance(args, dict):
        return ""
    for key in ("description", "command", "file_path", "pattern", "url", "query", "prompt", "path", "skill"):
        value = args.get(key)
        if isinstance(value, str) and value.strip():
            value = value.strip().splitlines()[0]
            # A path reads best as its last two parts.
            if key in ("file_path", "path") and "/" in value:
                value = "/".join(value.rstrip("/").split("/")[-2:])
            return value[:160]
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


def line_of(text, size=200):
    """The first line worth reading of some Markdown, without its decoration: a
    heading only when nothing follows it."""
    heading = ""
    for line in text.splitlines():
        bare = re.sub(r"\*\*|__|`", "", line).lstrip("#>*- \t").strip()
        if not bare:
            continue
        if line.lstrip().startswith("#"):
            heading = heading or bare
            continue
        return bare[:size]
    return heading[:size]


def stamp(text):
    """An ISO time as Claude Code or Codex writes it, nanoseconds and all, in
    whole seconds."""
    try:
        text = re.sub(r"(\.\d{6})\d+", r"\1", text).replace("Z", "+00:00")
        return int(datetime.datetime.fromisoformat(text).timestamp())
    except (AttributeError, TypeError, ValueError):
        return None


def activity(entries, sidechain=False):
    """What a conversation's end says: the person's last prompt and when it came,
    what the agent last wrote, its last tool calls (newest last), how many it has
    made since the prompt, what it is doing now, the git branch, and how full its
    context was at the last reply. `sidechain` reads a subagent's own file, where
    every record is one."""
    found = {"prompt": "", "asked": None, "said": "", "recent": [], "steps": 0,
             "doing": None, "branch": "", "tokens": None}
    last = None
    for r in entries:
        if r.get("isSidechain") and not sidechain:
            continue
        if r.get("gitBranch"):
            found["branch"] = r["gitBranch"]
        message = r.get("message") or {}
        at = stamp(r.get("timestamp"))
        content = message.get("content")
        if r.get("type") == "user":
            if isinstance(content, list) and any(isinstance(c, dict) and c.get("type") == "tool_result" for c in content):
                last = "result"
                continue
            words = said(content)
            if words and not automatic(r):
                found.update(prompt=line_of(words, 300), asked=at, steps=0, said="")
                last = "prompt"
        elif r.get("type") == "assistant" and isinstance(content, list):
            usage = message.get("usage") or {}
            if usage:
                found["tokens"] = sum(int(usage.get(k) or 0) for k in
                                      ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
            for c in content:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "tool_use":
                    name = c.get("name") or ""
                    step = {"at": at, "tool": name, "kind": kind_of(name), "text": brief(name, c.get("input"))}
                    found["recent"].append(step)
                    found["steps"] += 1
                    last = step
                elif c.get("type") == "text" and c.get("text", "").strip():
                    found["said"] = line_of(c["text"])
                    last = "said"
                elif c.get("type") == "thinking":
                    last = "thinking"
    found["recent"] = found["recent"][-RECENT:]
    # A tool call still waiting on its result is what it is doing; after a result
    # or a prompt it is thinking; after its own words it has finished talking.
    if isinstance(last, dict):
        found["doing"] = last
    elif last in ("result", "prompt", "thinking"):
        found["doing"] = {"kind": "think", "tool": "", "text": "", "at": None}
    elif last == "said":
        found["doing"] = {"kind": "write", "tool": "", "text": found["said"], "at": None}
    return found


class Titles:
    """The newest title in each transcript: one a person gave it (agent-name) beats
    the one Claude Code wrote (ai-title). And the person's last prompt, which
    Claude Code files as its own record too, for a session whose prompt has
    scrolled out of the transcript's end. These sit anywhere in a file that can be
    many megabytes, so each file is read once and then only what was added, with
    the offsets kept in the runtime directory between runs."""

    def __init__(self, path):
        self.path = path
        self.cache = load(path) if path else None
        if not isinstance(self.cache, dict):
            self.cache = {}
        self.changed = False

    def get(self, transcript_path):
        """The title and the last prompt."""
        if not transcript_path:
            return "", ""
        key = str(transcript_path)
        known = self.cache.get(key)
        offset, ai, named, prompt = (known if isinstance(known, list) and len(known) == 4 else (0, "", "", ""))
        try:
            size = transcript_path.stat().st_size
            if size < offset:
                offset, ai, named, prompt = 0, "", "", ""
            if size > offset:
                with open(transcript_path, "rb") as f:
                    f.seek(offset)
                    data = f.read()
                # Only whole lines; a line still being written is read next time.
                end = data.rfind(b"\n") + 1
                for line in data[:end].splitlines():
                    if b'"ai-title"' not in line and b'"agent-name"' not in line and b'"last-prompt"' not in line:
                        continue
                    try:
                        r = json.loads(line)
                    except ValueError:
                        continue
                    if r.get("type") == "ai-title" and r.get("aiTitle"):
                        ai = str(r["aiTitle"])
                    elif r.get("type") == "agent-name" and r.get("agentName"):
                        named = str(r["agentName"])
                    elif r.get("type") == "last-prompt" and r.get("lastPrompt"):
                        prompt = line_of(str(r["lastPrompt"]), 300)
                if end:
                    self.cache[key] = [offset + end, ai, named, prompt]
                    self.changed = True
        except OSError:
            return "", ""
        return named or ai, prompt

    def save(self):
        if not self.changed or not self.path:
            return
        try:
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.cache))
            tmp.replace(self.path)
        except OSError:
            pass


# The context windows models come with, to name one from a reading of its fill.
SIZES = (200_000, 400_000, 1_000_000)


def context_size(tokens, percent):
    """The window a session's context fills, when the status line did not say:
    the standard size nearest what its tokens and percentage imply."""
    if not tokens or not percent:
        return None
    implied = tokens / (float(percent) / 100)
    return min(SIZES, key=lambda size: abs(size - implied))


def subagents(path, now):
    """The subagents a session has started, from the files Claude Code keeps beside
    its transcript: running ones, and ones that finished a moment ago."""
    found = []
    if not path:
        return found
    for meta_path in (path.parent / path.stem / "subagents").glob("*.meta.json"):
        meta = load(meta_path)
        if not isinstance(meta, dict):
            continue
        log = meta_path.with_name(meta_path.name[: -len(".meta.json")] + ".jsonl")
        at = max(mtime(log), mtime(meta_path))
        done = bool(meta.get("finished"))
        if now - at > (SUB_DONE if done else SUB_STALE):
            continue
        seen = activity(records(log, SUB_TAIL), sidechain=True)
        found.append({
            "id": meta_path.name.split(".")[0],
            "title": meta.get("description") or meta.get("agentType") or "subagent",
            "type": meta.get("agentType") or "",
            "model": meta.get("pickedEffortModel") or meta.get("model") or "",
            "background": meta.get("requestShape") == "background",
            "state": "done" if done else ("working" if now - at < WORKING else "idle"),
            "at": int(at),
            "doing": seen["doing"],
            "steps": len(seen["recent"]),
            "said": seen["said"],
        })
    return sorted(found, key=lambda s: (s["state"] == "done", -s["at"]))


def job(jobs, job_id):
    """A background job's own account of itself: done, stopped or failed, a line
    on where it got to, the tasks it still has running, and the tokens it spent."""
    if not isinstance(job_id, str) or not re.fullmatch(r"[A-Za-z0-9-]+", job_id):
        return None
    s = load(jobs / job_id / "state.json")
    if not isinstance(s, dict):
        return None
    tasks = [t for t in s.get("fan") or [] if isinstance(t, dict) and not t.get("doneAt")]
    return {
        "state": s.get("state") or "",
        "detail": line_of(str(s.get("detail") or "")),
        "tasks": [{"kind": t.get("kind") or "", "label": line_of(str(t.get("label") or ""), 80)} for t in tasks],
        "tokens": s.get("tokens") if isinstance(s.get("tokens"), int) else None,
    }


def claude(base, sessions_dir, now, projects=None, jobs=None, titles=None, brief_only=False):
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
        key = process_key(s["pid"], s["started"])
        log = transcript(projects, known.get("sessionId") or s.get("id")) if projects else None
        entries = records(log) if log and not brief_only else []
        limit = stopped(entries)
        status = known.get("status")
        # The registry's own word for it, then the time since the status line ran.
        st = {"busy": "working", "idle": "idle", "waiting": "waiting"}.get(status) or state(now, at)
        since = (known.get("statusUpdatedAt") or 0) / 1000 or at
        background = known.get("kind") == "bg"
        own_job = job(jobs, known.get("jobId")) if jobs and background else None
        if background and st == "idle" and (
                (own_job and own_job["state"] in ("done", "stopped", "failed")) or now - since > JOB_DONE):
            st = "done"
        title, last_prompt = titles.get(log) if titles and log else ("", "")
        name = known.get("name") or ""
        # A derived name is Claude Code's placeholder (the folder and a few
        # letters); the transcript's title says what the session is about.
        if known.get("nameSource") == "derived" or not name:
            name = title or name
        seen = activity(entries) if entries else None
        if seen and not seen["prompt"]:
            seen["prompt"] = last_prompt
        tokens = seen["tokens"] if seen else None
        size = s.get("context_size") or context_size(tokens, s.get("context"))
        if tokens is None and size and s.get("context") is not None:
            tokens = round(float(s["context"]) / 100 * size)
        session = {
            "tool": "claude",
            "id": s.get("id") or path.stem,
            "cwd": cwd,
            "project": os.path.basename((s.get("project") or cwd).rstrip("/")),
            "model": s.get("model") or "",
            "context": s.get("context"),
            "context_size": size,
            "tokens": tokens,
            "cost": s.get("cost"),
            "lines": s.get("lines"),
            "at": int(at),
            "since": int(since),
            "started": int((known.get("startedAt") or 0) / 1000) or None,
            "state": st,
            "waiting": (known.get("waitingFor") or "") if st == "waiting" else "",
            "background": background,
            "job": own_job,
            "name": name,
            "pid": s["pid"],
            # When a usage limit stopped it, the time that limit resets; and
            # whether resume.py types into it then.
            "limited": limit["resets"] if limit and limit["resets"] > now else (0 if limit else None),
            "key": key,
            "resume": (base / "resume" / key).exists(),
            "subagents": subagents(log, now) if log and not brief_only else [],
        }
        if seen:
            session.update({k: seen[k] for k in ("prompt", "asked", "said", "recent", "steps", "doing", "branch")})
        sessions.append(session)
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
    for line in tail(path, 512 * 1024):
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


def codex_logs(root, now):
    """Session logs from the last week, newest first: the weekly limit outlives a quiet spell."""
    days = []
    for offset in range(8):
        day = datetime.date.fromtimestamp(now) - datetime.timedelta(days=offset)
        days.append(root / f"{day:%Y}" / f"{day:%m}" / f"{day:%d}")
    logs = [p for d in days for p in d.glob("*.jsonl")]
    return sorted(logs, key=mtime, reverse=True)


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


def codex_titles(path):
    """Codex's thread names by session id, the newest of each."""
    names = {}
    for line in tail(path):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict) and r.get("id") and r.get("thread_name"):
            names[r["id"]] = r["thread_name"]
    return names


def codex_command(payload):
    """What a Codex tool call ran: the command inside its code, when it has one."""
    raw = payload.get("input") if isinstance(payload.get("input"), str) else payload.get("arguments")
    if isinstance(raw, str):
        try:
            args = json.loads(raw)
            if isinstance(args, dict):
                cmd = args.get("cmd") or args.get("command")
                if isinstance(cmd, list):
                    cmd = " ".join(str(c) for c in cmd)
                if isinstance(cmd, str):
                    return line_of(cmd, 160)
        except ValueError:
            pass
        m = re.search(r"cmd\s*:\s*[`\"']([^`\"']+)", raw)
        if m:
            return line_of(m.group(1), 160)
        return line_of(raw, 160)
    return ""


def codex_activity(lines):
    """The same account as activity(), from a Codex session log's end, and whether
    a turn is open (started and not yet complete)."""
    found = {"prompt": "", "asked": None, "said": "", "recent": [], "steps": 0,
             "doing": None, "branch": "", "tokens": None, "size": None, "open": None}
    last = None
    for line in lines:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if not isinstance(r, dict):
            continue
        p = r.get("payload") or {}
        at = stamp(r.get("timestamp"))
        kind = p.get("type")
        if r.get("type") == "event_msg" and kind == "token_count":
            info = p.get("info") or {}
            last_use = info.get("last_token_usage") or {}
            if last_use.get("input_tokens") is not None:
                found["tokens"] = int(last_use["input_tokens"])
            if info.get("model_context_window"):
                found["size"] = int(info["model_context_window"])
        elif r.get("type") == "event_msg" and kind in ("task_started", "task_complete"):
            found["open"] = kind == "task_started"
        elif r.get("type") == "response_item" and kind in ("function_call", "custom_tool_call", "local_shell_call"):
            name = p.get("name") or "exec"
            step = {"at": at, "tool": name, "kind": kind_of(name), "text": codex_command(p)}
            found["recent"].append(step)
            found["steps"] += 1
            last = step
        elif r.get("type") == "response_item" and kind in ("function_call_output", "custom_tool_call_output"):
            last = "result"
        elif r.get("type") == "response_item" and kind == "message":
            text = " ".join(c.get("text", "") for c in p.get("content") or [] if isinstance(c, dict))
            if p.get("role") == "assistant" and text.strip():
                found["said"] = line_of(text)
                last = "said"
            elif p.get("role") == "user" and text.strip() and not text.lstrip().startswith("<"):
                found.update(prompt=line_of(text, 300), asked=at, steps=0, said="")
                last = "prompt"
        elif r.get("type") == "turn_context" and isinstance(p.get("git"), dict):
            found["branch"] = p["git"].get("branch") or found["branch"]
    found["recent"] = found["recent"][-RECENT:]
    if isinstance(last, dict):
        found["doing"] = last
    elif last in ("result", "prompt"):
        found["doing"] = {"kind": "think", "tool": "", "text": "", "at": None}
    elif last == "said":
        found["doing"] = {"kind": "write", "tool": "", "text": found["said"], "at": None}
    return found


def codex(root, auth_path, now, titles=None, brief_only=False):
    limits = None
    seen = None
    sessions = []
    names = titles or {}
    for path in codex_logs(root, now):
        at = mtime(path)
        lines = None
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
            sid = meta.get("id") or path.stem
            session = {
                "tool": "codex",
                "id": sid,
                "cwd": cwd,
                "project": os.path.basename(cwd.rstrip("/")),
                "model": meta.get("model") or "",
                "context": None,
                "at": int(at),
                "since": int(at),
                "state": state(now, at),
                "name": names.get(sid, ""),
                "subagents": [],
            }
            if not brief_only:
                act = codex_activity(lines if lines is not None else tail(path))
                # A finished turn is idle at once; an open one is working while it
                # still writes to its log.
                if act["open"] is False:
                    session["state"] = "idle"
                session["tokens"] = act["tokens"]
                session["context_size"] = act["size"]
                if act["tokens"] and act["size"]:
                    session["context"] = round(100 * act["tokens"] / act["size"])
                session.update({k: act[k] for k in ("prompt", "asked", "said", "recent", "steps", "doing", "branch")})
                if not session["name"]:
                    session["name"] = act["prompt"][:60]
            sessions.append(session)
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


# Waiting on the person first, then working, then the rest; newest first within each.
ORDER = {"waiting": 0, "working": 1, "idle": 2, "done": 3}


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    brief_only = "--brief" in sys.argv[1:]
    now = time.time() if not args else float(args[0])
    home = pathlib.Path(os.environ.get("HOME", "/nonexistent"))
    state_home = pathlib.Path(os.environ.get("XDG_STATE_HOME") or home / ".local/state")
    codex_home = pathlib.Path(os.environ.get("CODEX_HOME") or home / ".codex")
    runtime = pathlib.Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}")
    titles = Titles(runtime / "quiet-shell-agent-titles.json" if runtime.is_dir() else None)
    usage = state_home / "agent-usage"
    claude_limits, claude_sessions = claude(
        usage, home / ".claude/sessions", now, home / ".claude/projects", home / ".claude/jobs",
        titles, brief_only)
    titles.save()
    codex_limits, codex_sessions = codex(
        codex_home / "sessions", codex_home / "auth.json", now,
        codex_titles(codex_home / "session_index.jsonl"), brief_only)
    if not brief_only:
        project(claude_limits, usage / "claude-history.jsonl", now)
    sessions = sorted(claude_sessions + codex_sessions,
                      key=lambda s: (ORDER.get(s["state"], 2), -s["at"]))[:SHOWN_SESSIONS]
    if brief_only:
        for s in sessions:
            s.pop("pid", None)
            s["terminal"] = None
    else:
        place(sessions, runtime)
    print(json.dumps({
        "now": int(now),
        "claude": claude_limits,
        "codex": codex_limits,
        "sessions": sessions,
    }))


if __name__ == "__main__":
    main()
