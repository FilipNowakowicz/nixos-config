"""Digest recent Claude Code and Codex sessions in one repo for the miner.

usage: python3 -I digest.py --repo PATH [--worktrees DIR] [--since EPOCH]
                           [--max-chars N] > digest.md

Per session it keeps only what a lesson can come from: what the user asked or
corrected, tool calls that failed, commands repeated three or more times, hook
blocks, and the size of the session (calls, output tokens). Assistant prose and
successful tool output are left out, which keeps a week's digest near 40k
tokens. Sessions with the most friction come first; the rest are cut at
--max-chars.

Only the standard library is used, so the script runs with `python3 -I`.
"""

import argparse
import collections
import json
import os
import re
import sys
import time
from pathlib import Path

FAIL_RE = re.compile(
    r"(exit code:? [1-9]|\"exit_code\":[1-9]|Process exited with code [1-9]|Exit code [1-9]"
    r"|command not found|No such file or directory|Traceback|error:)",
    re.IGNORECASE,
)
# Text an agent harness injects as a "user" message rather than the person.
INJECTED = (
    "<",
    "# AGENTS.md",
    "Caveat:",
    "[Request interrupted",
    "This session is being continued",
    "Base directory for this skill",
)


def clip(text, n):
    text = " ".join(str(text).split())
    return text if len(text) <= n else text[: n - 1] + "…"


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(
            part.get("text", "") for part in content if isinstance(part, dict)
        )
    return ""


def read_jsonl(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    yield json.loads(line)
                except ValueError:
                    continue
    except OSError:
        return


class Session:
    def __init__(self, agent, path):
        self.agent, self.path = agent, path
        self.cwd = ""
        self.title = ""
        self.prompts, self.failures, self.hooks = [], [], []
        self.commands = collections.Counter()
        self.calls = 0
        self.output_tokens = 0

    def friction(self):
        repeated = sum(1 for n in self.commands.values() if n >= 3)
        return 3 * len(self.failures) + 2 * len(self.hooks) + repeated + len(self.prompts) // 3

    def render(self):
        out = [
            f"## {self.agent} session {Path(self.path).stem[-12:]} ({self.title or 'untitled'})",
            f"cwd: {self.cwd}; tool calls: {self.calls}; output tokens: {self.output_tokens}",
        ]
        if self.prompts:
            out.append("User said:")
            out += [f"- {p}" for p in self.prompts[:8]]
        if self.failures:
            out.append("Failed tool calls:")
            out += [f"- {f}" for f in self.failures[:10]]
        repeated = [(c, n) for c, n in self.commands.most_common(5) if n >= 3]
        if repeated:
            out.append("Repeated commands:")
            out += [f"- {n}x {clip(c, 160)}" for c, n in repeated]
        if self.hooks:
            out.append("Hook messages:")
            out += [f"- {h}" for h in self.hooks[:5]]
        return "\n".join(out)


def claude_session(path):
    s = Session("claude", path)
    pending = {}
    for rec in read_jsonl(path):
        kind = rec.get("type")
        s.cwd = rec.get("cwd") or s.cwd
        if kind == "ai-title":
            s.title = clip(rec.get("aiTitle") or rec.get("title") or "", 80)
        if rec.get("isSidechain"):
            continue
        msg = rec.get("message") or {}
        content = msg.get("content")
        if kind == "assistant":
            s.output_tokens += (msg.get("usage") or {}).get("output_tokens", 0) or 0
            for part in content if isinstance(content, list) else []:
                if part.get("type") != "tool_use":
                    continue
                s.calls += 1
                inp = part.get("input") or {}
                summary = inp.get("command") or inp.get("file_path") or inp.get("pattern") or ""
                pending[part.get("id")] = f"{part.get('name')}: {clip(summary, 160)}"
                if part.get("name") == "Bash" and inp.get("command"):
                    s.commands[inp["command"].strip()] += 1
        elif kind == "user":
            if rec.get("isMeta"):
                text = text_of(content)
                if "hook" in text.lower() and not text.startswith("Base directory"):
                    s.hooks.append(clip(text, 240))
                continue
            if isinstance(content, str) or (
                isinstance(content, list)
                and all(p.get("type") == "text" for p in content if isinstance(p, dict))
            ):
                text = text_of(content).strip()
                if text and not text.startswith(INJECTED):
                    s.prompts.append(clip(text, 500))
                continue
            for part in content if isinstance(content, list) else []:
                if part.get("type") != "tool_result":
                    continue
                body = text_of(part.get("content"))
                if part.get("is_error") or FAIL_RE.search(body[:2000]):
                    call = pending.get(part.get("tool_use_id"), "?")
                    s.failures.append(f"{call} -> {clip(body, 240)}")
    return s


def codex_session(path, roots):
    s = Session("codex", path)
    last = "?"
    for rec in read_jsonl(path):
        kind, p = rec.get("type"), rec.get("payload") or {}
        if kind == "session_meta":
            s.cwd = p.get("cwd", "")
            if not any(s.cwd == r or s.cwd.startswith(r + "/") for r in roots):
                return None
        elif kind == "event_msg" and p.get("type") == "token_count":
            usage = ((p.get("info") or {}).get("total_token_usage") or {})
            s.output_tokens = usage.get("output_tokens", s.output_tokens) or s.output_tokens
        elif kind == "response_item":
            t = p.get("type")
            if t == "message" and p.get("role") == "user":
                text = text_of(p.get("content")).strip()
                if text and not text.startswith(INJECTED):
                    s.prompts.append(clip(text, 500))
            elif t in ("custom_tool_call", "function_call"):
                s.calls += 1
                arg = p.get("input") or p.get("arguments") or ""
                for cmd in re.findall(r'cmd:\s*"((?:[^"\\]|\\.)*)"', str(arg)) or [str(arg)]:
                    s.commands[clip(cmd, 300)] += 1
                last = clip(arg, 160)
            elif t in ("custom_tool_call_output", "function_call_output"):
                out = p.get("output")
                body = out if isinstance(out, str) else text_of(out)
                if "blocked by PreToolUse hook" in body:
                    s.hooks.append(clip(body[body.find("blocked by"):], 240))
                elif FAIL_RE.search(body[:4000]):
                    s.failures.append(f"{last} -> {clip(body, 240)}")
    return s if s.cwd else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--worktrees", default="")
    ap.add_argument("--since", type=float, default=time.time() - 7 * 86400)
    ap.add_argument("--max-chars", type=int, default=160_000)
    ap.add_argument("--claude-projects", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--codex-sessions", default=os.path.expanduser("~/.codex/sessions"))
    args = ap.parse_args()

    roots = [args.repo.rstrip("/")] + ([args.worktrees.rstrip("/")] if args.worktrees else [])
    # Claude names a project directory after its path with / and . replaced by -.
    prefixes = [re.sub(r"[/.]", "-", r) for r in roots]

    def recent(path):
        try:
            return path.stat().st_mtime >= args.since
        except OSError:
            return False

    sessions = []
    projects = Path(args.claude_projects)
    if projects.is_dir():
        for d in projects.iterdir():
            if d.is_dir() and any(d.name == p or d.name.startswith(p + "-") for p in prefixes):
                sessions += [claude_session(f) for f in d.glob("*.jsonl") if recent(f)]
    codex = Path(args.codex_sessions)
    if codex.is_dir():
        for f in codex.rglob("*.jsonl"):
            if recent(f):
                s = codex_session(f, roots)
                if s:
                    sessions.append(s)

    sessions = [s for s in sessions if s.prompts or s.failures]
    sessions.sort(key=Session.friction, reverse=True)
    head = (
        f"# Agent session digest since {time.strftime('%Y-%m-%d', time.localtime(args.since))}\n"
        f"{len(sessions)} sessions ({sum(s.agent == 'claude' for s in sessions)} Claude, "
        f"{sum(s.agent == 'codex' for s in sessions)} Codex), most friction first.\n"
    )
    out, used, cut = [head], len(head), 0
    for s in sessions:
        block = s.render() + "\n"
        if used + len(block) > args.max_chars:
            cut += 1
            continue
        out.append(block)
        used += len(block)
    if cut:
        out.append(f"({cut} lower-friction sessions left out for length.)\n")
    sys.stdout.write("\n".join(out))


if __name__ == "__main__":
    main()
