#!/usr/bin/env python3
"""Read and set Samsung Galaxy Buds state over their manager channel.

Usage: buds.py read ADDRESS | buds.py set ADDRESS off|anc|ambient

Samsung's protocol is undocumented, so a message is only trusted if its checksum
passes. The layout follows GalaxyBudsClient, and was checked on Buds4 Pro. BlueZ
already reports one battery figure; this adds each bud, the case and noise control.
"""

import json
import re
import socket
import subprocess
import sys
import threading
import time

MANAGER_UUID = "2e73a4ad-332d-41fc-90e2-16bef06523f2"
STATUS, ACKNOWLEDGE, SET_NOISE_CONTROL = 0x61, 0x42, 0x78
START, END = 0xFD, 0xDD
MODES = {"off": 0, "anc": 1, "ambient": 2, "adaptive": 3}


def checksum(data):
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = (crc << 1 ^ 0x1021 if crc & 0x8000 else crc << 1) & 0xFFFF
    return crc


def frame(message, payload=b""):
    body = bytes([message]) + payload
    crc = checksum(body)
    size = len(body) + 2
    return bytes([START, size & 0xFF, size >> 8]) + body + bytes([crc & 0xFF, crc >> 8, END])


def frames(buffer):
    """Split a stream into (message, payload) pairs and return them with what's left."""
    found = []
    while len(buffer) >= 4:
        if buffer[0] != START:
            buffer = buffer[1:]
            continue
        size = (buffer[1] | buffer[2] << 8) & 0x3FF
        if len(buffer) < size + 4:
            break
        body, end = buffer[3 : 3 + size], buffer[3 + size]
        buffer = buffer[size + 4 :]
        if end == END and size >= 3 and checksum(body[:-2]) == body[-2] | body[-1] << 8:
            found.append((body[0], body[1:-2]))
    return found, buffer


def status(payload):
    """A bud that isn't linked reports 0%, which would read as flat, so leave it out."""
    linked = payload[6]
    mode = next((name for name, value in MODES.items() if value == payload[12]), None)
    return {
        "left": payload[2] if linked >> 4 else None,
        "right": payload[3] if linked & 15 else None,
        "case": payload[7] or None,
        "mode": mode,
    }


def channel(address):
    """The RFCOMM channel can differ between models and firmware, so ask the Buds.

    sdptool prints its records at once and then doesn't exit, so stop at the answer.
    """
    with subprocess.Popen(["sdptool", "records", address], stdout=subprocess.PIPE, text=True) as lookup:
        give_up = threading.Timer(8, lookup.kill)
        give_up.start()
        found = False
        try:
            for line in lookup.stdout:
                found = found or MANAGER_UUID in line
                match = re.search(r"Channel: (\d+)", line)
                if found and match:
                    return int(match.group(1))
            return None
        finally:
            give_up.cancel()
            lookup.kill()


def connect(address, port):
    # The Buds need a moment to release the channel after the last client leaves.
    for _ in range(8):
        link = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
        link.settimeout(8)
        try:
            link.connect((address, port))
            return link
        except OSError:
            link.close()
            time.sleep(1)
    return None


def wait_for(link, wanted):
    """Read until `wanted` picks a message out, or give up after a few seconds."""
    buffer = b""
    link.settimeout(0.25)
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        try:
            data = link.recv(4096)
        except TimeoutError:
            continue
        if not data:
            return None
        found, buffer = frames(buffer + data)
        for message, payload in found:
            result = wanted(message, payload)
            if result is not None:
                return result
    return None


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("read", "set"):
        sys.exit(2)
    command, address = sys.argv[1:3]
    target = MODES.get(sys.argv[3]) if command == "set" and len(sys.argv) > 3 else None
    if command == "set" and target is None:
        sys.exit(2)
    port = channel(address)
    link = connect(address, port) if port else None
    if link is None:
        sys.exit(1)
    with link:
        if command == "read":
            result = wait_for(link, lambda message, payload: status(payload) if message == STATUS and len(payload) > 12 else None)
        else:
            link.send(frame(SET_NOISE_CONTROL, bytes([target])))
            agreed = bytes([SET_NOISE_CONTROL, target])
            result = wait_for(link, lambda message, payload: {"mode": sys.argv[3]} if message == ACKNOWLEDGE and payload[:2] == agreed else None)
    if result is None:
        sys.exit(1)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
