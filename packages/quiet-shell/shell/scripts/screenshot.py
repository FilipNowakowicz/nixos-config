#!/usr/bin/env python3
"""Take a screenshot: screenshot.py area|window|screen|text [REGION].

Saves to the XDG pictures directory's Screenshots folder, copies it, and prints {"path": ...}. The text mode
reads the words in an area instead, copies them, saves nothing and prints
{"text": ...}. Prints nothing if the selection was cancelled. A REGION ("x,y wxh")
skips the selection, for an area the picker already has.
"""

import json
import os
import pathlib
import subprocess
import sys
import time


def run(*cmd, input=""):
    # Never inherit stdin: when it isn't a terminal, slurp waits to read window
    # boxes from it before drawing anything.
    return subprocess.run(cmd, input=input, capture_output=True, text=True, check=False)


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
    shot = subprocess.run(["grim", "-g", region, "-"], stdin=subprocess.DEVNULL, capture_output=True, check=False)
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
region = sys.argv[2] if len(sys.argv) > 2 else None
if not region and mode in ("area", "text"):
    region = run("slurp").stdout.strip()
elif not region and mode == "window":
    region = run("slurp", "-r", input=windows()).stdout.strip()
if mode != "screen" and not region:
    sys.exit(0)
if mode == "text":
    read_text(region)

pictures = run("xdg-user-dir", "PICTURES").stdout.strip()
if pictures and pathlib.Path(pictures).is_absolute() and pathlib.Path(pictures) != pathlib.Path.home():
    folder = pathlib.Path(pictures)
else:
    folder = pathlib.Path(os.environ.get("XDG_DATA_HOME", str(pathlib.Path.home() / ".local/share"))) / "pictures"
folder = folder / "Screenshots"
folder.mkdir(parents=True, exist_ok=True)
path = folder / time.strftime("Screenshot %Y-%m-%d at %H.%M.%S.png")

command = ["grim"] + (["-g", region] if region else []) + [str(path)]
if run(*command).returncode != 0 or not path.exists():
    sys.exit(1)
with open(path, "rb") as image:
    subprocess.run(["wl-copy", "--type", "image/png"], stdin=image, check=False)
print(json.dumps({"path": str(path)}))
