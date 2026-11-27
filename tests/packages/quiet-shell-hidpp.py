"""Check hidpp.py against a fake LIGHTSPEED receiver on a socket pair.

A socket pair keeps report boundaries like hidraw does, so the real write, select
and read path runs. The fake answers as the receiver did live: an error for an
empty slot, notifications mixed in, and feature indices that differ per device.
"""

import importlib.util
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
assert hidpp.reply(bytes([0x11, 1, 3, 0x1A, 55, 0, 0] + [0] * 13), 1, 3, 1) == bytes([55, 0, 0] + [0] * 13)
assert hidpp.reply(bytes([0x10, 1, 0x8F, 3, 0x1A, 9, 0]), 1, 3, 1) is None, "an error answers the request"
assert hidpp.reply(bytes([0x10, 1, 3, 0x10, 55, 0, 0]), 1, 3, 1) is False, "software id 0 is a notification"
assert hidpp.reply(bytes([0x10, 2, 3, 0x1A, 55, 0, 0]), 1, 3, 1) is False, "another device"

def receiver(slots):
    """slots: {device: (type, {feature id: index}, battery reply)}."""
    ours, theirs = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)

    def serve():
        while report := theirs.recv(64):
            _, device, index, address, *params = report
            # The receiver forwards unrelated traffic too.
            theirs.send(bytes([0x10, device, 0x41, 0x04, 0x61, 0, 0]))
            if device not in slots:
                theirs.send(bytes([0x10, device, 0x8F, index, address, 0x09, 0]))
                continue
            kind, features, battery = slots[device]
            if index == 0:
                found = features.get(params[0] << 8 | params[1], 0)
                answer = [found, 0, 0]
            elif index == features.get(hidpp.DEVICE_NAME_TYPE):
                answer = [kind]
            else:
                answer = battery
            theirs.send(bytes([0x11, device, index, address, *answer]).ljust(20, b"\0"))

    threading.Thread(target=serve, daemon=True).start()
    return ours

def found(slots):
    ours = receiver(slots)
    rx = hidpp.Receiver(ours.fileno(), time.monotonic() + 1)
    for device in range(1, 7):
        if (value := hidpp.mouse_level(rx, device)) is not None:
            return value
    return None

unified = {hidpp.DEVICE_NAME_TYPE: 4, hidpp.UNIFIED_BATTERY: 7}
assert found({2: (hidpp.MOUSE, unified, [62, 4, 0, 0])}) == 62, "slot 1 empty, mouse in slot 2"
assert found({1: (hidpp.MOUSE, {hidpp.DEVICE_NAME_TYPE: 3, hidpp.BATTERY_STATUS: 5}, [40, 30, 0])}) == 40
assert found({1: (0, unified, [80, 4, 0, 0])}) is None, "a keyboard's battery is not the mouse's"
assert found({1: (hidpp.MOUSE, unified, [0, 4, 0, 0])}) is None, "levels only"
assert found({1: (hidpp.MOUSE, {hidpp.DEVICE_NAME_TYPE: 3}, [])}) is None, "no battery feature"
assert found({}) is None, "asleep or unpaired"

# A receiver that never answers costs the deadline, not a hang.
quiet, _ = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
start = time.monotonic()
try:
    hidpp.Receiver(quiet.fileno(), start + 0.2).ask(1, 0, 0, 0, 5)
    raise AssertionError("expected a timeout")
except TimeoutError:
    assert time.monotonic() - start < 1

# Only Logitech nodes on the HID++ vendor page are opened.
with tempfile.TemporaryDirectory() as tmp:
    sysfs = pathlib.Path(tmp)
    for name, hid_id, descriptor in (
        ("hidraw0", "0003:0000046D:0000C54D", "05010902"),  # its mouse interface
        ("hidraw1", "0003:0000046D:0000C54D", "06 00ff0901"),
        ("hidraw2", "0018:000006CB:0000CD3E", "0600ff0901"),  # a touchpad
    ):
        device = sysfs / name / "device"
        device.mkdir(parents=True)
        (device / "uevent").write_text(f"HID_ID={hid_id}\n")
        (device / "report_descriptor").write_bytes(bytes.fromhex(descriptor))
    assert list(hidpp.nodes(sysfs)) == ["hidraw1"], list(hidpp.nodes(sysfs))
    # Its /dev node is missing (no grant): no battery, no error.
    assert hidpp.mouse_battery(sysfs, sysfs / "dev") is None

    # Asleep, the mouse answers nothing: the card keeps the last reading, dimmed,
    # until the receiver itself is gone.
    cache = sysfs / "cache" / "quiet-shell" / "mouse-battery"
    assert hidpp.remembered(None, True, cache) is None, "never seen"
    assert hidpp.remembered(73, True, cache) == {"level": 73, "awake": True}
    assert hidpp.remembered(None, True, cache) == {"level": 73, "awake": False}
    assert hidpp.remembered(None, False, cache) is None, "receiver unplugged"
    assert hidpp.remembered(70, True, cache)["level"] == 70 and cache.read_text() == "70"
    cache.write_text("junk")
    assert hidpp.remembered(None, True, cache) is None
print("quiet-shell hidpp: ok")
