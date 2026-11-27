"""Read a mouse on a Logitech receiver over HID++ 2.0: its name and battery.

No kernel driver claims the LIGHTSPEED receiver (046d:c54d), so its mouse never
reaches /sys/class/power_supply. A few short requests on the receiver's HID++
hidraw node, made from the status poll, do the job of a resident Solaar.

A request is [report, device, feature index, function << 4 | software id, params].
Feature indices differ per device, so each comes from the root feature first.

Every request to an awake mouse is radio traffic it answers on battery, so its
slot, feature indices and name are found once and cached, and the mouse is read
at most once a minute. A sleeping mouse is never reached: the receiver answers
for it that it is not connected, and the last reading stays.
"""

import json
import os
import pathlib
import select
import time

SHORT, LONG = 0x10, 0x11
OLD_ERROR, ERROR = 0x8F, 0xFF  # HID++ 1.0 (from the receiver) and 2.0 error replies
ERRORS = (OLD_ERROR, ERROR)
NOT_CONNECTED = 0x08  # the receiver's answer for a slot whose device has no link
SOFTWARE_ID = 0x0A  # nonzero, so a reply is never mistaken for a notification
DEVICE_NAME_TYPE, BATTERY_STATUS, UNIFIED_BATTERY = 0x0005, 0x1000, 0x1004
MOUSE = 3  # DeviceNameType's getDeviceType
EVERY = 60  # seconds between readings


class Failed(Exception):
    """The request was refused, with HID++ error `code`. `asleep` when the receiver
    refused it for a device with no link (a 2.0 error 8 is "busy" instead)."""

    def __init__(self, code, asleep=False):
        super().__init__(code)
        self.code = code
        self.asleep = asleep


def request(device, feature, function, *params):
    return bytes([SHORT, device, feature, function << 4 | SOFTWARE_ID, *params]).ljust(7, b"\0")


def reply(report, device, feature, function):
    """The answer's parameters, Failed(code) if the request was refused, or None if
    `report` is something else, such as a notification."""
    if len(report) < 7 or report[0] not in (SHORT, LONG) or report[1] != device:
        return None
    address = function << 4 | SOFTWARE_ID
    if report[2] == feature and report[3] == address:
        return bytes(report[4:])
    if report[2] in ERRORS and report[3] == feature and report[4] == address:
        return Failed(report[5], asleep=report[2] == OLD_ERROR and report[5] == NOT_CONNECTED)
    return None


class Receiver:
    def __init__(self, fd, deadline):
        self.fd = fd
        self.deadline = deadline

    def ask(self, device, feature, function, *params):
        os.write(self.fd, request(device, feature, function, *params))
        while (left := self.deadline - time.monotonic()) > 0:
            if not select.select([self.fd], [], [], left)[0]:
                break
            answer = reply(os.read(self.fd, 64), device, feature, function)
            if isinstance(answer, Failed):
                raise answer
            if answer is not None:
                return answer
        raise TimeoutError

    def feature(self, device, feature):
        answer = self.ask(device, 0, 0, feature >> 8, feature & 0xFF)
        # Index 0 is the root feature itself, the answer for "not supported".
        return answer[0] or None


def discover(receiver):
    """The mouse's slot, name and the features to read. An empty slot and a
    sleeping device are both refused as not connected."""
    for device in range(1, 7):
        try:
            kind = receiver.feature(device, DEVICE_NAME_TYPE)
        except Failed:
            continue
        if kind is None or receiver.ask(device, kind, 2)[0] != MOUSE:
            continue
        length, name = receiver.ask(device, kind, 0)[0], b""
        while len(name) < length:
            chunk = receiver.ask(device, kind, 1, len(name)).rstrip(b"\0")
            if not chunk:
                break
            name += chunk
        found = {"device": device, "name": name[:length].decode(errors="replace").strip() or "Mouse"}
        for key, feature in (("unified", UNIFIED_BATTERY), ("battery", BATTERY_STATUS)):
            if (index := receiver.feature(device, feature)) is not None:
                found[key] = index
        return found
    return None


def measure(receiver, found):
    """The battery now: one request to the mouse."""
    device, now = found["device"], {"level": None, "charging": False}
    if "unified" in found:
        # State of charge, level flags, charging (1 on, 2 slowly, 3 full on the
        # charger, 4 error), external power.
        answer = receiver.ask(device, found["unified"], 1)
        now["level"], now["charging"] = answer[0], answer[2] in (1, 2, 3)
    elif "battery" in found:
        # Level, next level, status (1 recharging, 2 almost full, 3 full, 4 slowly).
        answer = receiver.ask(device, found["battery"], 0)
        now["level"], now["charging"] = answer[0], answer[2] in (1, 2, 3, 4)
    if not 0 < (now["level"] or 0) <= 100:
        now["level"] = None  # a mouse that reports only coarse levels says 0
    return now


def nodes(sysfs):
    """Logitech hidraw nodes whose reports open on the vendor page HID++ uses."""
    for node in sorted(sysfs.glob("hidraw*")):
        try:
            uevent = (node / "device/uevent").read_text()
            descriptor = (node / "device/report_descriptor").read_bytes()
        except OSError:
            continue
        if "HID_ID=0003:0000046D:" in uevent and descriptor.startswith(b"\x06\x00\xff"):
            yield node.name


def load(cache):
    try:
        state = json.loads(cache.read_text())
        return state if isinstance(state, dict) else {}
    except (OSError, ValueError):
        return {}


def save(cache, state):
    try:
        cache.parent.mkdir(parents=True, exist_ok=True)
        temporary = cache.with_suffix(".tmp")
        temporary.write_text(json.dumps(state))
        temporary.replace(cache)
    except OSError:
        pass


def shown(state):
    if state.get("level") is None:
        return None
    return {key: state.get(key) for key in ("name", "level", "charging")}


def opened(path):
    return os.open(path, os.O_RDWR | os.O_NONBLOCK)


def mouse(sysfs, dev, cache, timeout=1.0, clock=time.time, opener=opened):
    """What the card shows, { name, level, charging }: the last reading, or
    None with no receiver plugged in or no reading yet."""
    names = list(nodes(sysfs))
    if not names:
        return None
    state = load(cache)
    if clock() - state.get("at", 0) < EVERY:
        return shown(state)
    deadline = time.monotonic() + timeout
    for name in names:
        try:
            fd = opener(dev / name)
        except OSError:
            continue  # no udev grant for this node
        try:
            receiver = Receiver(fd, deadline)
            found = state.get("found") or discover(receiver)
            if found is None:
                continue
            try:
                state.update(measure(receiver, found), found=found, name=found["name"], at=clock())
            except Failed as refused:
                if not refused.asleep:
                    # Not the mouse cached for this slot any more: look again.
                    state.pop("found", None)
                    state.pop("at", None)
                # Asleep: asking again costs the mouse nothing, so no wait either.
            save(cache, state)
            return shown(state)
        except (OSError, TimeoutError, Failed, IndexError):
            pass  # a slow or odd answer changes nothing: keep the last reading
        finally:
            os.close(fd)
    return shown(state)
