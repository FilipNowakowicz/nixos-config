"""Ask a mouse on a Logitech receiver for its battery over HID++ 2.0.

No kernel driver claims the LIGHTSPEED receiver (046d:c54d), so its mouse never
reaches /sys/class/power_supply. A few short requests on the receiver's HID++
hidraw node, made once per status poll, do the job of a resident Solaar.

A request is [report, device, feature index, function << 4 | software id, params].
Feature indices differ per device, so each comes from the root feature first.
"""

import os
import pathlib
import select
import time

SHORT, LONG = 0x10, 0x11
ERRORS = (0x8F, 0xFF)  # HID++ 1.0 and 2.0 error replies
SOFTWARE_ID = 0x0A  # nonzero, so a reply is never mistaken for a notification
DEVICE_NAME_TYPE, BATTERY_STATUS, UNIFIED_BATTERY = 0x0005, 0x1000, 0x1004
MOUSE = 3  # DeviceNameType's getDeviceType


def request(device, feature, function, *params):
    return bytes([SHORT, device, feature, function << 4 | SOFTWARE_ID, *params]).ljust(7, b"\0")


def reply(report, device, feature, function):
    """The answer's parameters, None if the request failed, or False if `report` is
    something else, such as a notification."""
    if len(report) < 7 or report[0] not in (SHORT, LONG) or report[1] != device:
        return False
    address = function << 4 | SOFTWARE_ID
    if report[2] == feature and report[3] == address:
        return bytes(report[4:])
    if report[2] in ERRORS and report[3] == feature and report[4] == address:
        return None
    return False


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
            if answer is not False:
                return answer
        raise TimeoutError

    def feature(self, device, feature):
        answer = self.ask(device, 0, 0, feature >> 8, feature & 0xFF)
        # Index 0 is the root feature itself, the answer for "not supported".
        return answer[0] if answer and answer[0] else None


def mouse_level(receiver, device):
    """The battery percentage of the mouse paired at `device`, else None. An empty
    slot or a sleeping mouse fails on the first request."""
    kind = receiver.feature(device, DEVICE_NAME_TYPE)
    if kind is None:
        return None
    answer = receiver.ask(device, kind, 2)
    if not answer or answer[0] != MOUSE:
        return None
    if (unified := receiver.feature(device, UNIFIED_BATTERY)) is not None:
        answer = receiver.ask(device, unified, 1)  # get_status: state of charge first
    elif (status := receiver.feature(device, BATTERY_STATUS)) is not None:
        answer = receiver.ask(device, status, 0)  # discharge level first
    else:
        return None
    # A mouse that reports only coarse levels says 0 here.
    return answer[0] if answer and 0 < answer[0] <= 100 else None


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


def mouse_battery(sysfs=pathlib.Path("/sys/class/hidraw"), dev=pathlib.Path("/dev"), timeout=1.0):
    deadline = time.monotonic() + timeout
    for name in nodes(sysfs):
        try:
            fd = os.open(dev / name, os.O_RDWR | os.O_NONBLOCK)
        except OSError:
            continue  # no udev grant for this node
        try:
            receiver = Receiver(fd, deadline)
            for device in range(1, 7):
                if (level := mouse_level(receiver, device)) is not None:
                    return level
        except (OSError, TimeoutError):
            pass
        finally:
            os.close(fd)
    return None
