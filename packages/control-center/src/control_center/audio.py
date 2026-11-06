"""Structured audio discovery and stable-name default selection, without GTK."""

import json
import subprocess


MEDIA = {"sink": ("Audio/Sink",), "source": ("Audio/Source", "Audio/Source/Virtual")}


def parse_devices(text):
    objects = json.loads(text)
    if not isinstance(objects, list):
        raise ValueError("Expected a PipeWire object list")
    defaults = {}
    nodes = []
    for obj in objects:
        if not isinstance(obj, dict):
            continue
        if obj.get("type") == "PipeWire:Interface:Metadata" and obj.get("props", {}).get("metadata.name") == "default":
            for entry in obj.get("metadata", []):
                if entry.get("subject") != 0:
                    continue
                value = entry.get("value")
                if isinstance(value, dict) and isinstance(value.get("name"), str):
                    defaults[entry.get("key")] = value["name"]
        if obj.get("type") == "PipeWire:Interface:Node":
            props = obj.get("info", {}).get("props", {})
            name = props.get("node.name")
            if isinstance(name, str) and name and "\x00" not in name:
                nodes.append((obj.get("id"), name, props))
    state = {}
    for role, classes in MEDIA.items():
        default = defaults.get(f"default.audio.{role}")
        entries = []
        for idx, name, props in nodes:
            if props.get("media.class") not in classes:
                continue
            # Ambiguous logical names cannot be safely selected.
            if sum(node_name == name for _, node_name, _ in nodes) != 1:
                continue
            desc = str(props.get("node.description") or props.get("node.nick") or name)
            active = name == default
            if role == "sink" and not active and any(token in desc.lower() for token in ("hdmi", "displayport", "display port", "monitor")):
                continue
            entries.append({"id": idx, "name": name, "desc": desc, "default": active})
        state[role + "s"] = entries
        # Missing or ambiguous nodes cannot confirm a switch.
        state[role + "_node_name"] = default if any(e["name"] == default for e in entries) else None
    return state


def write_default(command):
    """Preflight presence/class by name; numeric object reuse cannot retarget it."""
    role = command[4].removeprefix("default.configured.audio.")
    target = json.loads(command[5])["name"]
    try:
        result = subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=3, check=False)
        if result.returncode != 0:
            return "failed"
        devices = parse_devices(result.stdout)
        if not any(node["name"] == target for node in devices[role + "s"]):
            return "failed"
    except (OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired):
        return "failed"  # No write has started.
    try:
        result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=8, check=False)
        return "ok" if result.returncode == 0 else "failed"
    except subprocess.TimeoutExpired:
        return "unknown"  # Preference may already have changed; do not repeat.
    except OSError:
        return "failed"
