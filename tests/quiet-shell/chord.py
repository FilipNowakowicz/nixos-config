#!/usr/bin/env python3
"""Press keys in a real order with a virtual keyboard, which wtype chords can't do.

Usage: chord.py STEP..., where a step is S+ or S- for SUPER, T+ or T- for Tab, or a
number of milliseconds to wait. SUPER+Tab tapped quickly is: S+ T+ 15 T- 15 S-
"""

import os
import pathlib
import socket
import struct
import sys
import time

KEYMAP = b"""xkb_keymap {
xkb_keycodes "q" { minimum = 8; maximum = 255; <TAB> = 23; <LWIN> = 133; };
xkb_types "q" { include "complete" };
xkb_compatibility "q" { include "complete" };
xkb_symbols "q" {
  key <TAB> { [ Tab, ISO_Left_Tab ] };
  key <LWIN> { [ Super_L ] };
  modifier_map Mod4 { <LWIN> };
};
};
\0"""
KEYS = {"S": 125, "T": 15}
MOD4 = 0x40

path = pathlib.Path(os.environ["XDG_RUNTIME_DIR"], os.environ["WAYLAND_DISPLAY"])
sock = socket.socket(socket.AF_UNIX)
sock.connect(str(path))


def message(obj, opcode, payload=b""):
    return struct.pack("<IHH", obj, opcode, 8 + len(payload)) + payload


def send(obj, opcode, payload=b""):
    sock.sendall(message(obj, opcode, payload))


def text(value):
    raw = value.encode() + b"\0"
    return struct.pack("<I", len(raw)) + raw + b"\0" * (-len(raw) % 4)


def receive(count):
    data = b""
    while len(data) < count:
        data += sock.recv(count - len(data))
    return data


REGISTRY, DONE, SEAT, MANAGER, KEYBOARD = 2, 3, 4, 5, 6
send(1, 1, struct.pack("<I", REGISTRY))
send(1, 0, struct.pack("<I", DONE))
found = {}
while True:
    obj, opcode, size = struct.unpack("<IHH", receive(8))
    body = receive(size - 8)
    if obj == DONE:
        break
    if obj == REGISTRY and opcode == 0:
        name, length = struct.unpack_from("<II", body)
        found[body[8 : 8 + length - 1].decode()] = name
for interface, new_id in (("wl_seat", SEAT), ("zwp_virtual_keyboard_manager_v1", MANAGER)):
    send(REGISTRY, 0, struct.pack("<I", found[interface]) + text(interface) + struct.pack("<II", 1, new_id))
send(MANAGER, 0, struct.pack("<II", SEAT, KEYBOARD))

keymap = os.memfd_create("keymap")
os.write(keymap, KEYMAP)
socket.send_fds(sock, [message(KEYBOARD, 0, struct.pack("<II", 1, len(KEYMAP)))], [keymap])
time.sleep(0.05)


def stamp():
    return int(time.monotonic() * 1000) & 0xFFFFFFFF


held = 0
for step in sys.argv[1:]:
    if step.isdigit():
        time.sleep(int(step) / 1000)
        continue
    down = step[1] == "+"
    send(KEYBOARD, 1, struct.pack("<III", stamp(), KEYS[step[0]], int(down)))
    if step[0] == "S":
        held = MOD4 if down else 0
        send(KEYBOARD, 2, struct.pack("<IIII", held, 0, 0, 0))
time.sleep(0.05)
