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
    networks, ssid = [], ""
    seen = set()
    for line in (run("nmcli", "-t", "-f", "active,ssid,signal", "dev", "wifi") or "").splitlines():
        parts = re.split(r"(?<!\\):", line)
        if len(parts) < 3 or not parts[1]:
            continue
        name = parts[1].replace("\\:", ":")
        active = parts[0] == "yes"
        ssid = name if active else ssid
        if name not in seen:
            seen.add(name)
            networks.append({"name": name, "active": active, "signal": int(parts[2] or 0)})
    return {"on": radio.strip() == "enabled", "ssid": ssid, "networks": networks[:8]}


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
        if len(bits) == 3:
            devices.append({"addr": bits[1], "name": bits[2], "connected": bits[1] in connected})
    return {"on": "Powered: yes" in show, "devices": devices}


def vpn():
    tail = run("tailscale", "status", "--json")
    mull = run("mullvad", "status")
    if tail is None and mull is None:
        return None
    tail_on = False
    if tail:
        try:
            tail_on = json.loads(tail).get("BackendState") == "Running"
        except ValueError:
            pass
    mull_on = bool(mull) and mull.lstrip().startswith("Connected")
    return {"tailscale": tail_on, "mullvad": mull_on}


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
            entries.append({"name": name, "desc": desc, "active": active})
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


def media():
    out = run("playerctl", "metadata", "--format", "{{status}}\t{{title}}\t{{artist}}\t{{mpris:artUrl}}")
    if not out:
        return None
    bits = (out.rstrip("\n").split("\t") + [""] * 4)[:4]
    if not bits[1]:
        return None
    return {"playing": bits[0] == "Playing", "title": bits[1], "artist": bits[2], "art": bits[3]}


def night():
    return run("pgrep", "-x", "wlsunset") is not None


def awake():
    return run("systemctl", "--user", "is-active", "--quiet", "caffeinate.service") is not None


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
    "media": media(),
    "night": night(),
    "awake": awake(),
}))
