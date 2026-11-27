"""Check hidpp.py against a fake LIGHTSPEED receiver on a socket pair.

A socket pair keeps report boundaries like hidraw does, so the real write, select
and read path runs. The fake answers as the receiver and a PRO X2 SUPERSTRIKE did
live: "not connected" for an empty slot or a sleeping mouse, notifications mixed
in, and the mouse's own feature indices.
"""

import importlib.util
import json
import pathlib
import socket
import sys
import tempfile
import threading
import time

spec = importlib.util.spec_from_file_location("hidpp", sys.argv[1])
hidpp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hidpp)

assert hidpp.request(1, 0, 0, 0x10, 0x04) == bytes([0x10, 1, 0, 0x0A, 0x10, 0x04, 0])
assert hidpp.reply(bytes([0x11, 1, 3, 0x1A, 55] + [0] * 15), 1, 3, 1) == bytes([55] + [0] * 15)
refused = hidpp.reply(bytes([0x10, 1, 0x8F, 3, 0x1A, 8, 0]), 1, 3, 1)
assert isinstance(refused, hidpp.Failed) and refused.code == hidpp.NOT_CONNECTED and refused.asleep
assert hidpp.reply(bytes([0x10, 1, 3, 0x10, 55, 0, 0]), 1, 3, 1) is None, "software id 0 is a notification"
assert hidpp.reply(bytes([0x10, 2, 3, 0x1A, 55, 0, 0]), 1, 3, 1) is None, "another device"

# Captured live: the feature indices, and what each read answers.
NAME = b"PRO X2 SUPERSTRIKE"
FEATURES = {hidpp.DEVICE_NAME_TYPE: 3, hidpp.UNIFIED_BATTERY: 6}


class Mouse:
    def __init__(self, kind=hidpp.MOUSE, features=FEATURES, level=73, charging=0):
        self.kind, self.features, self.awake = kind, features, True
        self.level, self.charging = level, charging
        self.asked = 0

    def answer(self, index, function, params):
        self.asked += 1
        if index == 0:
            return [self.features.get(params[0] << 8 | params[1], 0)]
        feature = {i: f for f, i in self.features.items()}[index]
        return {
            hidpp.DEVICE_NAME_TYPE: lambda: {0: [len(NAME)], 1: list(NAME[params[0]:params[0] + 16]), 2: [self.kind]}[function],
            hidpp.UNIFIED_BATTERY: lambda: [self.level, 8, self.charging, 0],
            hidpp.BATTERY_STATUS: lambda: [self.level, 30, self.charging],
        }[feature]()


def receiver(slots):
    ours, theirs = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)

    def serve():
        while report := theirs.recv(64):
            _, device, index, address, *params = report
            # The receiver forwards unrelated traffic too.
            theirs.send(bytes([0x10, device, 0x41, 0x04, 0x61, 0, 0]))
            mouse = slots.get(device)
            if mouse is None or not mouse.awake:
                theirs.send(bytes([0x10, device, 0x8F, index, address, hidpp.NOT_CONNECTED, 0]))
                continue
            try:
                answer = mouse.answer(index, address >> 4, params)
            except KeyError:  # 2.0 error 6: invalid feature index
                theirs.send(bytes([0x11, device, 0xFF, index, address, 6]).ljust(20, b"\0"))
                continue
            theirs.send(bytes([0x11, device, index, address, *answer]).ljust(20, b"\0"))

    threading.Thread(target=serve, daemon=True).start()
    return ours.detach()


def read(slots):
    rx = hidpp.Receiver(receiver(slots), time.monotonic() + 1)
    found = hidpp.discover(rx)
    return found and {**hidpp.measure(rx, found), "name": found["name"]}


superstrike = {"name": "PRO X2 SUPERSTRIKE", "level": 73, "charging": False}
assert read({2: Mouse()}) == superstrike, "slot 1 empty, the mouse in slot 2"
assert read({1: Mouse(charging=1)})["charging"], "on the cable"
assert read({1: Mouse(charging=3)})["charging"], "full, still on the cable"
older = {hidpp.DEVICE_NAME_TYPE: 3, hidpp.BATTERY_STATUS: 5}
assert read({1: Mouse(features=older, level=40)}) == {**superstrike, "level": 40}
assert read({1: Mouse(kind=0)}) is None, "a keyboard is not the mouse"
assert read({1: Mouse(level=0)})["level"] is None, "coarse levels only"
assert read({}) is None, "nothing paired"

# A receiver that never answers costs the deadline, not a hang.
quiet, _ = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
start = time.monotonic()
try:
    hidpp.Receiver(quiet.fileno(), start + 0.2).ask(1, 0, 0, 0, 5)
    raise AssertionError("expected a timeout")
except TimeoutError:
    assert time.monotonic() - start < 1

with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    sysfs, dev, cache = root / "sys", root / "dev", root / "cache/mouse.json"
    # Only Logitech nodes on the HID++ vendor page are opened.
    for name, hid_id, descriptor in (
        ("hidraw0", "0003:0000046D:0000C54D", "05010902"),  # its mouse interface
        ("hidraw1", "0003:0000046D:0000C54D", "0600ff0901"),
        ("hidraw2", "0018:000006CB:0000CD3E", "0600ff0901"),  # a touchpad
    ):
        node = sysfs / name / "device"
        node.mkdir(parents=True)
        (node / "uevent").write_text(f"HID_ID={hid_id}\n")
        (node / "report_descriptor").write_bytes(bytes.fromhex(descriptor))
    assert list(hidpp.nodes(sysfs)) == ["hidraw1"], list(hidpp.nodes(sysfs))
    assert hidpp.mouse(sysfs, dev, cache) is None, "no grant on the node: no card, no error"
    assert hidpp.mouse(root / "none", dev, cache) is None, "no receiver"

    mouse, now = Mouse(), [1000.0]
    opened = []

    def poll():
        def opener(path):
            opened.append(path.name)
            return receiver({1: mouse})
        return hidpp.mouse(sysfs, dev, cache, clock=lambda: now[0], opener=opener)

    assert poll() == superstrike and opened == ["hidraw1"]
    first = mouse.asked
    # Within the minute the cache answers, and the mouse hears nothing.
    mouse.level = 60
    now[0] += 30
    assert poll()["level"] == 73 and mouse.asked == first
    # After it, one reading is one request: the battery. The rest is cached.
    now[0] += 31
    assert poll()["level"] == 60 and mouse.asked == first + 1, mouse.asked - first
    # Asleep, the last reading stays, and costs no wait: the next poll asks again.
    mouse.awake = False
    now[0] += 61
    assert poll() == {**superstrike, "level": 60}
    mouse.awake, mouse.level, mouse.charging = True, 55, 1
    now[0] += 1
    assert poll() == {**superstrike, "level": 55, "charging": True}, "read as soon as it wakes"
    # A cached index the mouse refuses (another mouse in the slot) is found again
    # on the next poll; the last reading stays meanwhile.
    state = json.loads(cache.read_text())
    state["found"]["unified"], state["at"] = 12, 0
    cache.write_text(json.dumps(state))
    assert poll()["level"] == 55 and "found" not in json.loads(cache.read_text())
    mouse.level = 50
    assert poll()["level"] == 50 and json.loads(cache.read_text())["found"]["unified"] == 6
    # HID++ 2.0 error 8 is "busy", not the receiver's "not connected".
    busy = hidpp.reply(bytes([0x11, 1, 0xFF, 6, 0x1A, 8] + [0] * 14), 1, 6, 1)
    assert isinstance(busy, hidpp.Failed) and not busy.asleep
    assert refused.asleep
print("quiet-shell hidpp: ok")
