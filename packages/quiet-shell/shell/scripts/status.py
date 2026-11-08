#!/usr/bin/env python3
"""Print one JSON snapshot of system state for the quiet shell.

Each probe fails soft: a missing tool reports `null`, so the shell can show a
control as unavailable rather than as off. Tests fake the commands on PATH.
"""

import json
import os
import pathlib
import re
import subprocess
import sys


def run(*cmd, timeout=3):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.stdout if out.returncode == 0 else None


def wifi():
    radio = run("nmcli", "radio", "wifi")
    if radio is None:
        return None
    known = set()
    for line in (run("nmcli", "-t", "-f", "name,type", "connection", "show") or "").splitlines():
        parts = re.split(r"(?<!\\):", line)
        if len(parts) == 2 and parts[1].endswith("wireless"):
            known.add(parts[0].replace("\\:", ":"))
    # One name can have many access points, and the one in use is rarely the strongest.
    networks = {}
    # Cached results: letting nmcli rescan here can outlast the timeout and blank the list.
    for line in (run("nmcli", "-t", "-f", "active,ssid,signal,security", "dev", "wifi", "list", "--rescan", "no") or "").splitlines():
        parts = re.split(r"(?<!\\):", line)
        if len(parts) < 4 or not parts[1]:
            continue
        name = parts[1].replace("\\:", ":")
        signal = int(parts[2] or 0)
        entry = networks.setdefault(name, {
            "name": name,
            "active": False,
            "signal": signal,
            "security": parts[3].replace("\\:", ":"),
            "known": name in known,
        })
        entry["active"] = entry["active"] or parts[0] == "yes"
        entry["signal"] = max(entry["signal"], signal)
    ordered = sorted(networks.values(), key=lambda n: (not n["active"], not n["known"], -n["signal"]))
    ssid = ordered[0]["name"] if ordered and ordered[0]["active"] else ""
    return {"on": radio.strip() == "enabled", "ssid": ssid, "networks": ordered[:8]}


# Unnamed devices report an address as their name. While pairing it can be another
# address of the same device, so comparing against its own address isn't enough.
ADDRESS = re.compile(r"(?:[0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}")
GALAXY_MANAGER = "2e73a4ad-332d-41fc-90e2-16bef06523f2"
LOW_ENERGY = re.compile(r"^LE[-_ ]+|[-_ ]+LE$")


def same_device(name):
    """Earbuds and headphones can also advertise a low-energy twin, as in LE_Buds."""
    return LOW_ENERGY.sub("", name).casefold()


def galaxy_buds(devices):
    """Galaxy Buds are the paired device offering Samsung's manager service."""
    for device in devices:
        info = run("bluetoothctl", "info", device["addr"]) or ""
        if GALAXY_MANAGER in info:
            battery = re.search(r"Battery Percentage: .*\((\d+)\)", info)
            return {**device, "battery": int(battery.group(1)) if battery else None}
    return None


def bluetooth():
    show = run("bluetoothctl", "show")
    if show is None:
        return None
    devices = []
    connected = set()
    for line in (run("bluetoothctl", "devices", "Connected") or "").splitlines():
        bits = line.split(" ", 2)
        if len(bits) == 3:
            connected.add(bits[1])
    for line in (run("bluetoothctl", "devices", "Paired") or "").splitlines():
        bits = line.split(" ", 2)
        if len(bits) != 3:
            continue
        unnamed = ADDRESS.fullmatch(bits[2])
        if unnamed and bits[1] not in connected:
            continue
        devices.append({
            "addr": bits[1],
            "name": "Bluetooth device" if unnamed else bits[2],
            "connected": bits[1] in connected,
        })
    paired = {d["addr"] for d in devices}
    names = {same_device(d["name"]) for d in devices}
    nearby = []
    for line in (run("bluetoothctl", "devices") or "").splitlines():
        bits = line.split(" ", 2)
        if len(bits) != 3 or bits[1] in paired or ADDRESS.fullmatch(bits[2]):
            continue
        if same_device(bits[2]) in names:
            continue
        names.add(same_device(bits[2]))
        nearby.append({"addr": bits[1], "name": bits[2]})
    return {"on": "Powered: yes" in show, "devices": devices, "nearby": nearby[:6], "buds": galaxy_buds(devices)}


def vpn():
    tail = run("tailscale", "status", "--json")
    mull = run("mullvad", "status")
    if tail is None and mull is None:
        return None
    tail_on, nodes, exit_node = False, [], ""
    if tail:
        try:
            parsed = json.loads(tail)
            tail_on = parsed.get("BackendState") == "Running"
            for peer in (parsed.get("Peer") or {}).values():
                if peer.get("ExitNodeOption"):
                    nodes.append(peer.get("HostName", ""))
                if peer.get("ExitNode"):
                    exit_node = peer.get("HostName", "")
        except (ValueError, AttributeError):
            pass
    mull_on = bool(mull) and mull.lstrip().startswith("Connected")
    # The relay name starts with the country, as in gb-lon-wg-004.
    relay = re.search(r"Relay:\s+([a-z]{2})-", mull or "")
    wanted = re.search(r"Location:\s+country ([a-z]{2})", run("mullvad", "relay", "get") or "")
    return {
        "tailscale": tail_on,
        "mullvad": mull_on,
        "country": wanted.group(1) if wanted else (relay.group(1) if relay else ""),
        "exitNodes": sorted(nodes),
        "exitNode": exit_node,
    }


def mullvad_countries():
    """`mullvad relay list` is long, so this runs only when the picker opens."""
    found = re.findall(r"^(\S.*) \(([a-z]{2})\)$", run("mullvad", "relay", "list", timeout=8) or "", re.M)
    return [{"name": name, "code": code} for name, code in found]


def level(target):
    out = run("wpctl", "get-volume", target)
    if not out:
        return None
    match = re.search(r"([0-9.]+)", out)
    if not match:
        return None
    return {"level": round(float(match.group(1)) * 100), "muted": "[MUTED]" in out}


def audio_devices():
    """Stable PipeWire names, since numeric ids can be reused."""
    dump = run("pw-dump")
    if dump is None:
        return None
    try:
        objects = json.loads(dump)
    except ValueError:
        return None
    defaults, nodes = {}, []
    for obj in objects:
        if obj.get("type") == "PipeWire:Interface:Metadata" and obj.get("props", {}).get("metadata.name") == "default":
            for entry in obj.get("metadata", []):
                value = entry.get("value")
                if entry.get("subject") == 0 and isinstance(value, dict):
                    defaults[entry.get("key")] = value.get("name")
        if obj.get("type") == "PipeWire:Interface:Node":
            nodes.append(obj.get("info", {}).get("props", {}))
    result = {}
    for role, classes in (("sinks", ("Audio/Sink",)), ("sources", ("Audio/Source", "Audio/Source/Virtual"))):
        default = defaults.get(f"default.audio.{role[:-1]}")
        entries = []
        for props in nodes:
            name = props.get("node.name")
            if props.get("media.class") not in classes or not name:
                continue
            desc = str(props.get("node.description") or name)
            active = name == default
            if role == "sinks" and not active and re.search(r"hdmi|displayport|monitor", desc, re.I):
                continue
            # The description repeats the sound card, so devices on one card look alike.
            entries.append({"name": name, "desc": str(props.get("node.nick") or desc), "active": active})
        result[role] = entries
    return result


def brightness():
    out = run("brightnessctl", "-m")
    if not out:
        return None
    match = re.search(r"(\d+)%", out)
    return int(match.group(1)) if match else None


def power_profile():
    out = run("powerprofilesctl", "get")
    return out.strip() if out else None


def battery():
    root = pathlib.Path(os.environ.get("QUIET_POWER_SUPPLY", "/sys/class/power_supply"))
    for path in sorted(root.glob("BAT*")):
        try:
            return {
                "level": int((path / "capacity").read_text()),
                "charging": (path / "status").read_text().strip() in ("Charging", "Full"),
            }
        except (OSError, ValueError):
            continue
    return None


def timezone():
    """The zone /etc/localtime names, as timedatectl sets it."""
    try:
        return os.readlink("/etc/localtime").partition("zoneinfo/")[2] or None
    except OSError:
        return None


def night():
    return run("pgrep", "-x", "wlsunset") is not None


def awake():
    return run("systemctl", "--user", "is-active", "--quiet", "caffeinate.service") is not None


if sys.argv[1:] == ["countries"]:
    print(json.dumps(mullvad_countries()))
    sys.exit()

print(json.dumps({
    "wifi": wifi(),
    "bluetooth": bluetooth(),
    "vpn": vpn(),
    "sink": level("@DEFAULT_AUDIO_SINK@"),
    "source": level("@DEFAULT_AUDIO_SOURCE@"),
    "devices": audio_devices(),
    "brightness": brightness(),
    "profile": power_profile(),
    "battery": battery(),
    "night": night(),
    "timezone": timezone(),
    "awake": awake(),
}))
