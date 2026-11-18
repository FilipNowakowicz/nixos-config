#!/usr/bin/env python3
"""Print the paired phones as JSON: reachable or not, battery, signal and the
notifications waiting on them.

Everything comes from KDE Connect's daemon on the session bus (see
home/profiles/phone.nix), asked through busctl so tests can fake it like any
other command. Without the daemon the list is simply empty.
"""

import json
import subprocess

SERVICE = "org.kde.kdeconnect"
DEVICE = "org.kde.kdeconnect.device"
# The overview shows a few; the rest are counted.
SHOWN = 4


def call(path, interface, method, *args):
    try:
        out = subprocess.run(
            ["busctl", "--user", "-j", "call", SERVICE, path, interface, method, *args],
            capture_output=True, text=True, timeout=3,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout)["data"][0]
    except (ValueError, KeyError, IndexError, TypeError):
        return None


def properties(path, interface):
    """Every property of one interface, unwrapped from busctl's typed values."""
    found = call(path, "org.freedesktop.DBus.Properties", "GetAll", "s", interface)
    if not isinstance(found, dict):
        return {}
    return {k: v.get("data") for k, v in found.items() if isinstance(v, dict)}


def device(id_):
    path = f"/modules/kdeconnect/devices/{id_}"
    info = properties(path, DEVICE)
    if not info:
        return None
    reachable = bool(info.get("isReachable"))
    phone = {
        "id": id_,
        "name": info.get("name") or "Phone",
        "type": info.get("type") or "",
        "reachable": reachable,
        "battery": None,
        "signal": None,
        "notifications": [],
        "more": 0,
    }
    if not reachable:
        return phone
    battery = properties(f"{path}/battery", f"{DEVICE}.battery")
    if battery.get("hasBattery"):
        phone["battery"] = {"charge": battery.get("charge"), "charging": bool(battery.get("isCharging"))}
    signal = properties(f"{path}/connectivity_report", f"{DEVICE}.connectivity_report")
    if signal:
        phone["signal"] = {"strength": signal.get("cellularNetworkStrength"), "type": signal.get("cellularNetworkType") or ""}
    ids = call(f"{path}/notifications", f"{DEVICE}.notifications", "activeNotifications") or []
    notes = []
    for nid in ids:
        n = properties(f"{path}/notifications/{nid}", f"{DEVICE}.notifications.notification")
        if not n:
            continue
        notes.append({
            "id": nid,
            "app": n.get("appName") or "",
            "title": n.get("title") or "",
            "text": n.get("text") or "",
            "reply": bool(n.get("replyId")),
        })
    # Newest last on the phone, newest first here.
    notes.reverse()
    phone["notifications"] = notes[:SHOWN]
    phone["more"] = max(0, len(notes) - SHOWN)
    return phone


def main():
    # Paired phones, whether or not they are in reach right now.
    ids = call("/modules/kdeconnect", "org.kde.kdeconnect.daemon", "devices", "bb", "false", "true") or []
    phones = [p for p in (device(i) for i in ids if isinstance(i, str)) if p]
    phones.sort(key=lambda p: (not p["reachable"], p["type"] != "phone", p["name"]))
    print(json.dumps({"phones": phones}))


if __name__ == "__main__":
    main()
