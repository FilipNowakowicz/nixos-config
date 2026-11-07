#!/usr/bin/env python3
"""Take a screenshot: screenshot.py area|window|screen|text.

Saves to ~/Pictures/Screenshots, copies it, and prints {"path": ...}. The text mode
reads the words in an area instead, copies them, saves nothing and prints
{"text": ...}. Prints nothing if the selection was cancelled.
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


def read_text(region):
    """The words in a region, through OCR. The picture never touches the disk."""
    shot = subprocess.run(["grim", "-g", region, "-"], capture_output=True, check=False)
    if shot.returncode != 0:
        sys.exit(1)
    ocr = subprocess.run(["tesseract", "-", "-", "-l", "eng+pol"], input=shot.stdout, capture_output=True, check=False)
    if ocr.returncode != 0:
        sys.exit(1)
    text = ocr.stdout.decode(errors="replace").strip()
    if text:
        subprocess.run(["wl-copy", "--type", "text/plain"], input=text.encode(), check=False)
    print(json.dumps({"text": text}))
    sys.exit(0)


mode = sys.argv[1]
region = None
if mode in ("area", "text"):
    region = run("slurp").stdout.strip()
elif mode == "window":
    region = run("slurp", "-r", input=windows()).stdout.strip()
if mode != "screen" and not region:
    sys.exit(0)
if mode == "text":
    read_text(region)

folder = pathlib.Path.home() / "Pictures/Screenshots"
folder.mkdir(parents=True, exist_ok=True)
path = folder / time.strftime("Screenshot %Y-%m-%d at %H.%M.%S.png")

command = ["grim"] + (["-g", region] if region else []) + [str(path)]
if run(*command).returncode != 0 or not path.exists():
    sys.exit(1)
with open(path, "rb") as image:
    subprocess.run(["wl-copy", "--type", "image/png"], stdin=image, check=False)
print(json.dumps({"path": str(path)}))
