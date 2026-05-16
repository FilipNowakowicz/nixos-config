#!/usr/bin/env bash
set -euo pipefail

repo_root="$(
  git rev-parse --show-toplevel 2>/dev/null || pwd
)"
cd "$repo_root"

python3 - "$@" <<'PY'
from pathlib import Path
from urllib.parse import unquote, urlsplit
import re
import subprocess
import sys


repo = Path.cwd()
external_schemes = {
    "app",
    "file",
    "ftp",
    "git",
    "http",
    "https",
    "mailto",
    "ssh",
    "tel",
}


def tracked_markdown_files() -> list[Path]:
    output = subprocess.check_output(["git", "ls-files", "*.md"], text=True)
    return [path for line in output.splitlines() if line and (path := repo / line).exists()]


def strip_fenced_code(text: str) -> str:
    return re.sub(r"(?ms)^```.*?^```", "", text)


def local_targets(text: str) -> list[tuple[int, str]]:
    cleaned = strip_fenced_code(text)
    targets: list[tuple[int, str]] = []

    patterns = [
        re.compile(r"!?\[[^\]\n]+\]\(([^)\s]+)(?:\s+['\"][^)]*['\"])?\)"),
        re.compile(r"(?m)^\s*\[[^\]\n]+\]:\s+(\S+)"),
        re.compile(r"""(?i)\b(?:href|src)=["']([^"']+)["']"""),
    ]

    for pattern in patterns:
        for match in pattern.finditer(cleaned):
            line = cleaned.count("\n", 0, match.start()) + 1
            targets.append((line, match.group(1)))

    return targets


def is_external(target: str) -> bool:
    parsed = urlsplit(target)
    return bool(parsed.netloc) or parsed.scheme.lower() in external_schemes


def normalize_target(target: str) -> str:
    target = target.strip()
    if target.startswith("<") and target.endswith(">"):
        target = target[1:-1]
    return target


def check_target(source: Path, line: int, raw_target: str) -> str | None:
    target = normalize_target(raw_target)
    if not target or target.startswith("#") or is_external(target):
        return None

    parsed = urlsplit(target)
    if parsed.path == "":
        return None

    path = unquote(parsed.path)
    candidate = Path(path) if Path(path).is_absolute() else source.parent / path

    if candidate.exists():
        return None

    return f"{source.relative_to(repo)}:{line}: missing link target: {raw_target}"


def main() -> int:
    if len(sys.argv) > 1:
        markdown_files = [repo / arg for arg in sys.argv[1:]]
    else:
        markdown_files = tracked_markdown_files()

    failures: list[str] = []
    for source in markdown_files:
        if not source.exists():
            failures.append(f"{source.relative_to(repo)}: file does not exist")
            continue

        text = source.read_text(encoding="utf-8")
        for line, target in local_targets(text):
            failure = check_target(source, line, target)
            if failure:
                failures.append(failure)

    if failures:
        print("Broken Markdown links:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1

    print(f"Checked {len(markdown_files)} Markdown files")
    return 0


raise SystemExit(main())
PY
