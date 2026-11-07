#!/usr/bin/env python3
"""Press, drag and release with a virtual pointer, which wlrctl can't do.

Usage: drag.py X1 Y1 X2 Y2, in compositor coordinates. Talks the Wayland wire protocol
directly because the release has to come from the same connection as the press.
"""

import os
import pathlib
import socket
import struct
import subprocess
import sys
import time

BTN_LEFT = 0x110
x1, y1, x2, y2 = map(int, sys.argv[1:5])
path = pathlib.Path(os.environ["XDG_RUNTIME_DIR"], os.environ["WAYLAND_DISPLAY"])
sock = socket.socket(socket.AF_UNIX)
sock.connect(str(path))


def send(obj, opcode, payload=b""):
    sock.sendall(struct.pack("<IHH", obj, opcode, 8 + len(payload)) + payload)


def text(value):
    raw = value.encode() + b"\0"
    return struct.pack("<I", len(raw)) + raw + b"\0" * (-len(raw) % 4)


def receive(count):
    data = b""
    while len(data) < count:
        data += sock.recv(count - len(data))
    return data


REGISTRY, DONE, MANAGER, POINTER = 2, 3, 4, 5
send(1, 1, struct.pack("<I", REGISTRY))
send(1, 0, struct.pack("<I", DONE))
manager = None
while True:
    obj, opcode, size = struct.unpack("<IHH", receive(8))
    body = receive(size - 8)
    if obj == DONE:
        break
    if obj == REGISTRY and opcode == 0:
        name, length = struct.unpack_from("<II", body)
        if body[8 : 8 + length - 1] == b"zwlr_virtual_pointer_manager_v1":
            manager = name
assert manager is not None, "no virtual pointer protocol"
send(REGISTRY, 0, struct.pack("<I", manager) + text("zwlr_virtual_pointer_manager_v1") + struct.pack("<II", 1, MANAGER))
send(MANAGER, 0, struct.pack("<II", 0, POINTER))


def stamp():
    return int(time.monotonic() * 1000) & 0xFFFFFFFF


def frame():
    send(POINTER, 4)
    time.sleep(0.03)


def go(x, y):
    subprocess.run(["hyprctl", "dispatch", f"hl.dsp.cursor.move({{x={x},y={y}}})"], check=True, capture_output=True)
    # Clients only hear about the warp once something real moves.
    send(POINTER, 0, struct.pack("<Iii", stamp(), 256, 0))
    frame()


def button(state):
    send(POINTER, 2, struct.pack("<III", stamp(), BTN_LEFT, state))
    frame()


go(x1, y1)
button(1)
steps = 14
for step in range(1, steps + 1):
    go(x1 + (x2 - x1) * step // steps, y1 + (y2 - y1) * step // steps)
go(x2, y2)
time.sleep(0.15)
if "QUIET_DRAG_SHOT" in os.environ:
    subprocess.run(["grim", "-o", os.environ["QUIET_DRAG_OUTPUT"], os.environ["QUIET_DRAG_SHOT"]], check=False, timeout=12)
button(0)
time.sleep(0.1)
