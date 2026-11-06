#!/usr/bin/env python3
"""Take a screenshot: screenshot.py area|window|screen.

Saves to ~/Pictures/Screenshots, copies it, and prints the path. Prints nothing if
the selection was cancelled.
"""

import json
import os
import pathlib
import subprocess
import sys
import time


def run(*cmd, **kwargs):
    return subprocess.run(cmd, capture_output=True, text=True, check=False, **kwargs)


def windows():
    """Rectangles of the windows on visible desktops, for slurp to offer."""
    clients = json.loads(run("hyprctl", "-j", "clients").stdout or "[]")
    monitors = json.loads(run("hyprctl", "-j", "monitors").stdout or "[]")
    shown = {m["activeWorkspace"]["id"] for m in monitors}
    boxes = []
    for client in clients:
        if client["workspace"]["id"] in shown:
            x, y = client["at"]
            w, h = client["size"]
            boxes.append(f"{x},{y} {w}x{h}")
    return "\n".join(boxes) + "\n"


mode = sys.argv[1]
folder = pathlib.Path.home() / "Pictures/Screenshots"
folder.mkdir(parents=True, exist_ok=True)
path = folder / time.strftime("Screenshot %Y-%m-%d at %H.%M.%S.png")

region = None
if mode == "area":
    region = run("slurp").stdout.strip()
elif mode == "window":
    region = run("slurp", "-r", input=windows()).stdout.strip()
if mode != "screen" and not region:
    sys.exit(0)

command = ["grim"] + (["-g", region] if region else []) + [str(path)]
if run(*command).returncode != 0 or not path.exists():
    sys.exit(1)
with open(path, "rb") as image:
    subprocess.run(["wl-copy", "--type", "image/png"], stdin=image, check=False)
print(path)
