"""Read-only state gathering. All functions return plain dicts/values
suitable for JSON or for direct consumption by the UI refresh pass."""

import json
import os
import re
import time

from gi.repository import Gio, GLib

from . import actions
from ._proc import _run
from .capabilities import capabilities


def _nmcli_split(line):
    """Split nmcli -t output, respecting backslash-escaped colons."""
    parts = []
    cur = []
    i = 0
    while i < len(line):
        c = line[i]
        if c == "\\" and i + 1 < len(line):
            cur.append(line[i + 1])
            i += 2
            continue
        if c == ":":
            parts.append("".join(cur))
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    parts.append("".join(cur))
    return parts


def _band(mhz):
    if mhz >= 5000:
        return "5 GHz"
    if mhz >= 2400:
        return "2.4 GHz"
    return ""


def gather_wifi():
    state = {
        "enabled": False, "connected": False,
        "ssid": None, "signal_pct": 0, "band": "", "freq_mhz": 0,
        "security": "", "ip": "", "gateway": "",
        "networks": [],
    }
    out, ok = _run(["nmcli", "radio", "wifi"])
    state["enabled"] = ok and out.strip() == "enabled"

    if not state["enabled"]:
        return state

    out, _ = _run([
        "nmcli", "-t", "-f",
        "GENERAL.DEVICE,GENERAL.TYPE,GENERAL.CONNECTION,IP4.ADDRESS,IP4.GATEWAY",
        "dev", "show",
    ])
    current_dev = None
    wifi_dev = None
    for raw in out.splitlines():
        parts = _nmcli_split(raw)
        if len(parts) < 2:
            continue
        k, v = parts[0], parts[1]
        if k == "GENERAL.DEVICE":
            current_dev = v
        elif k == "GENERAL.TYPE":
            if v == "wifi":
                wifi_dev = current_dev
        elif k == "GENERAL.CONNECTION" and current_dev == wifi_dev:
            if v and v != "--":
                state["connected"] = True
        elif k.startswith("IP4.ADDRESS") and current_dev == wifi_dev:
            state["ip"] = v.split("/")[0]
        elif k == "IP4.GATEWAY" and current_dev == wifi_dev:
            state["gateway"] = v

    # `list --rescan no` returns cached results immediately instead of
    # waiting on a scan, so repeated polls stay snappy. The kernel /
    # NetworkManager triggers periodic rescans on its own.
    out, _ = _run([
        "nmcli", "-t", "-f",
        "ACTIVE,SSID,SIGNAL,FREQ,SECURITY",
        "dev", "wifi", "list", "--rescan", "no",
    ])
    # Multiple rows per SSID (one per BSSID). Dedup keeping the row with
    # active=yes when present, otherwise the highest signal.
    by_ssid = {}
    for raw in out.splitlines():
        parts = _nmcli_split(raw)
        if len(parts) < 5:
            continue
        active, ssid, signal_s, freq_s, sec = (
            parts[0], parts[1], parts[2], parts[3], parts[4]
        )
        if not ssid:
            continue
        try:
            signal_i = int(signal_s)
        except ValueError:
            signal_i = 0
        try:
            freq_mhz = int(freq_s.split()[0])
        except (ValueError, IndexError):
            freq_mhz = 0
        net = {
            "ssid": ssid,
            "signal": signal_i,
            "freq_mhz": freq_mhz,
            "band": _band(freq_mhz),
            "security": sec or "Open",
            "active": active == "yes",
        }
        prev = by_ssid.get(ssid)
        if (prev is None
                or (net["active"] and not prev["active"])
                or (net["active"] == prev["active"]
                    and net["signal"] > prev["signal"])):
            by_ssid[ssid] = net

    for net in by_ssid.values():
        if net["active"]:
            state["ssid"] = net["ssid"]
            state["signal_pct"] = net["signal"]
            state["freq_mhz"] = net["freq_mhz"]
            state["band"] = net["band"]
            state["security"] = net["security"]
            break
    state["networks"] = sorted(by_ssid.values(), key=lambda n: -n["signal"])
    return state


def gather_bluetooth():
    state = {"powered": False, "devices": [], "primary": None}
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        proxy = Gio.DBusProxy.new_sync(
            bus, Gio.DBusProxyFlags.NONE, None,
            "org.bluez", "/", "org.freedesktop.DBus.ObjectManager", None,
        )
        result = proxy.call_sync(
            "GetManagedObjects", None, Gio.DBusCallFlags.NONE, 1500, None,
        )
        objs = result.unpack()[0]
    except (GLib.Error, Exception):
        return state

    for _path, ifaces in objs.items():
        adapter = ifaces.get("org.bluez.Adapter1")
        if adapter:
            state["powered"] = bool(adapter.get("Powered", False))

    for _path, ifaces in objs.items():
        dev = ifaces.get("org.bluez.Device1")
        if not dev or not dev.get("Paired"):
            continue
        bat = ifaces.get("org.bluez.Battery1") or {}
        device = {
            "address": dev.get("Address", ""),
            "alias": dev.get("Alias") or dev.get("Name", "Unknown"),
            "connected": bool(dev.get("Connected", False)),
            "icon": dev.get("Icon", ""),
            "battery": bat.get("Percentage") if "Percentage" in bat else None,
        }
        state["devices"].append(device)
    state["devices"].sort(
        key=lambda d: (not d["connected"], d["alias"].lower())
    )
    for d in state["devices"]:
        if d["connected"]:
            state["primary"] = d
            break
    return state


def _wpctl_source_pretty(desc):
    """Friendlier display for wpctl source descriptions (esp. bluez)."""
    m = re.match(r"bluez_input\.([0-9A-Fa-f:]+)", desc)
    if m:
        return f"Bluetooth input ({m.group(1)[-5:]})"
    return desc


def _is_hidden_output_sink(desc, default=False):
    """Hide monitor/HDMI sinks from the picker unless they are active."""
    if default:
        return False
    d = (desc or "").lower()
    return any(token in d for token in (
        "hdmi", "displayport", "display port", "monitor",
    ))


def _parse_wpctl_status(text):
    sinks = []
    sources = []
    section = None
    default_sink_desc = ""
    default_source_desc = ""
    default_filter_source_desc = ""
    for raw in text.splitlines():
        stripped = raw.strip()
        if stripped.startswith("├─ Sinks") or stripped.startswith("└─ Sinks"):
            section = "sinks"
            continue
        if stripped.startswith("├─ Sources") or stripped.startswith("└─ Sources"):
            section = "sources"
            continue
        if stripped.startswith("├─ Filters") or stripped.startswith("└─ Filters"):
            section = "filters"
            continue
        for marker in ("├─ Streams", "├─ Devices",
                       "├─ Clients", "└─ Streams",
                       "└─ Devices", "└─ Clients"):
            if stripped.startswith(marker):
                section = None
                break
        if section not in ("sinks", "sources", "filters"):
            continue
        m = re.match(
            r"^[│\s]*(\*?)\s*(\d+)\.\s+(.+?)(?:\s+\[(?:vol:|.+\])\s*[0-9.]*\s*(?:MUTED)?\s*\])?\s*$",
            raw,
        )
        if not m:
            continue
        default = m.group(1) == "*"
        idx = int(m.group(2))
        # Strip bracket suffixes (e.g. "[Audio/Source]") for filters.
        desc = re.sub(r"\s*\[[^\]]+\]\s*$", "", m.group(3)).strip()
        entry = {"id": idx, "desc": desc, "default": default}
        if section == "sinks":
            if not _is_hidden_output_sink(desc, default=default):
                sinks.append(entry)
            if default:
                default_sink_desc = desc
        elif section == "sources":
            sources.append(entry)
            if default:
                default_source_desc = desc
        elif section == "filters" and default and "source" in raw.lower():
            # WirePlumber marks the active source-side filter with `*`.
            default_filter_source_desc = desc

    if not default_source_desc and default_filter_source_desc:
        default_source_desc = _wpctl_source_pretty(default_filter_source_desc)

    return {
        "sinks": sinks,
        "sources": sources,
        "sink_name": default_sink_desc or "—",
        "source_name": default_source_desc or "—",
    }


def _wpctl_inspect_desc(target):
    """Return node.description for a wpctl target, or '' if unavailable."""
    out, ok = _run(["wpctl", "inspect", target])
    if not ok:
        return ""
    m = re.search(r'node\.description\s*=\s*"([^"]+)"', out)
    return m.group(1) if m else ""


def gather_audio():
    state = {
        "sink_volume_pct": 0, "sink_muted": False, "sink_name": "—",
        "source_volume_pct": 0, "source_muted": False, "source_name": "—",
        "sinks": [], "sources": [],
    }
    for key, target in (("sink", "@DEFAULT_AUDIO_SINK@"),
                        ("source", "@DEFAULT_AUDIO_SOURCE@")):
        out, ok = _run(["wpctl", "get-volume", target])
        if not ok:
            continue
        m = re.search(r"Volume:\s*([0-9.]+)(\s*\[MUTED\])?", out)
        if m:
            state[f"{key}_volume_pct"] = round(float(m.group(1)) * 100)
            state[f"{key}_muted"] = bool(m.group(2))

    status_out, _ = _run(["wpctl", "status"])
    state.update(_parse_wpctl_status(status_out))

    # Prefer the friendly node.description over whatever fell out of the
    # status table (status sometimes points at a bluez_input filter that
    # has an ugly machine-name desc).
    sink_desc = _wpctl_inspect_desc("@DEFAULT_AUDIO_SINK@")
    if sink_desc:
        state["sink_name"] = sink_desc
    source_desc = _wpctl_inspect_desc("@DEFAULT_AUDIO_SOURCE@")
    if source_desc:
        state["source_name"] = source_desc

    return state


def gather_battery():
    state = {"percent": 0, "status": "Unknown", "charging": False,
             "time_str": "—"}
    base = "/sys/class/power_supply/BAT0"
    if not os.path.isdir(base):
        # Try any BAT*
        for entry in sorted(os.listdir("/sys/class/power_supply")):
            if entry.startswith("BAT"):
                base = f"/sys/class/power_supply/{entry}"
                break
        else:
            return state

    def _r(p):
        try:
            with open(p) as f:
                return f.read().strip()
        except OSError:
            return ""

    try:
        state["percent"] = int(_r(f"{base}/capacity") or "0")
    except ValueError:
        pass
    status = _r(f"{base}/status") or "Unknown"
    state["status"] = status
    state["charging"] = status in ("Charging", "Full")

    energy_now = _r(f"{base}/energy_now") or _r(f"{base}/charge_now")
    energy_full = _r(f"{base}/energy_full") or _r(f"{base}/charge_full")
    power_now = _r(f"{base}/power_now") or _r(f"{base}/current_now")
    try:
        en = int(energy_now); ef = int(energy_full); pw = int(power_now)
    except ValueError:
        en = ef = pw = 0

    if status == "Full":
        state["time_str"] = "full"
    elif pw > 0 and ef > 0:
        if status == "Discharging":
            mins = (en / pw) * 60
        elif status == "Charging":
            mins = ((ef - en) / pw) * 60
        else:
            mins = 0
        if mins > 0:
            h = int(mins // 60); m = int(mins % 60)
            state["time_str"] = f"{h}h {m}m"
    return state


def gather_brightness():
    state = {"percent": 100}
    out, ok = _run(["brightnessctl", "-m"])
    if ok:
        parts = out.strip().split(",")
        if len(parts) >= 4:
            try:
                state["percent"] = int(parts[3].rstrip("%"))
            except ValueError:
                pass
    return state


def gather_power_profile():
    try:
        props = Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SYSTEM,
            Gio.DBusProxyFlags.DO_NOT_LOAD_PROPERTIES,
            None,
            "org.freedesktop.UPower.PowerProfiles",
            "/org/freedesktop/UPower/PowerProfiles",
            "org.freedesktop.DBus.Properties",
            None,
        )
        profile = props.call_sync(
            "Get",
            GLib.Variant(
                "(ss)",
                (
                    "org.freedesktop.UPower.PowerProfiles",
                    "ActiveProfile",
                ),
            ),
            Gio.DBusCallFlags.NONE,
            500,
            None,
        ).unpack()[0]
        if hasattr(profile, "unpack"):
            profile = profile.unpack()
        if isinstance(profile, str) and profile:
            return profile
    except (GLib.Error, Exception):
        pass

    out, ok = _run(["powerprofilesctl", "get"])
    if ok:
        return out.strip()
    return "balanced"


def gather_dnd():
    out, ok = _run(["makoctl", "mode"])
    if ok:
        modes = [m.strip() for m in out.splitlines() if m.strip()]
        # makoctl mode prints current modes, one per line ("default", or
        # extra modes when stacked). Active when any non-default mode set.
        active = [m for m in modes if m and m != "default"]
        mode = active[0] if active else (modes[0] if modes else "default")
        return {"mode": mode, "enabled": bool(active)}
    return {"mode": "default", "enabled": False}


def gather_tailscale():
    state = {"enabled": False, "ip": "", "name": "", "os": "",
             "peers": [], "peer_count": 0, "exit_node": "None"}
    out, ok = _run(["tailscale", "status", "--json"], timeout=2.0)
    if not ok:
        return state
    try:
        data = json.loads(out)
    except (json.JSONDecodeError, ValueError):
        return state

    state["enabled"] = data.get("BackendState") == "Running"
    self_node = data.get("Self") or {}
    ips = self_node.get("TailscaleIPs") or []
    state["ip"] = next((ip for ip in ips if "." in ip), "")
    state["name"] = self_node.get("HostName", "")
    state["os"] = self_node.get("OS", "")

    peers = [{
        "name": state["name"],
        "ip": state["ip"],
        "online": True,
        "this": True,
        "os": state["os"],
        "exit_node": False,
    }]
    for _key, peer in (data.get("Peer") or {}).items():
        pips = peer.get("TailscaleIPs") or []
        peers.append({
            "name": (peer.get("HostName")
                     or (peer.get("DNSName") or "").split(".")[0]
                     or "?"),
            "ip": next((ip for ip in pips if "." in ip), ""),
            "online": bool(peer.get("Online", False)),
            "this": False,
            "os": peer.get("OS", ""),
            "exit_node": bool(peer.get("ExitNode", False)),
        })
    state["peers"] = peers
    state["peer_count"] = len(peers)
    exit_node = next((p for p in peers if p["exit_node"]), None)
    state["exit_node"] = exit_node["name"] if exit_node else "None"
    return state


def gather_mullvad():
    state = {"connected": False, "location": "—", "country": "", "city": "",
             "preferred": ""}
    out, _ = _run(["mullvad", "status"])
    for raw in out.splitlines():
        line = raw.strip()
        if line.startswith("Connected") or line.startswith("Connecting"):
            state["connected"] = True
        m = re.match(r"Visible location:\s*([^.]+)\.", line)
        if m:
            loc = m.group(1).strip()
            state["location"] = loc
            parts = [s.strip() for s in loc.split(",")]
            if len(parts) >= 2:
                state["country"] = parts[0]
                state["city"] = parts[1]
            else:
                state["country"] = loc

    out, _ = _run(["mullvad", "relay", "get"])
    m = re.search(r"Location:\s*(.+)$", out, re.MULTILINE)
    if m:
        state["preferred"] = m.group(1).strip()
    return state


def gather_cpu_temp():
    candidates = []
    base_dir = "/sys/class/hwmon"
    if not os.path.isdir(base_dir):
        return None
    for hwmon in os.listdir(base_dir):
        base = f"{base_dir}/{hwmon}"
        try:
            with open(f"{base}/name") as f:
                name = f.read().strip()
        except OSError:
            continue
        if name not in ("coretemp", "k10temp", "zenpower"):
            continue
        try:
            entries = os.listdir(base)
        except OSError:
            continue
        for entry in entries:
            if entry.startswith("temp") and entry.endswith("_input"):
                try:
                    with open(f"{base}/{entry}") as f:
                        candidates.append(int(f.read().strip()))
                except (OSError, ValueError):
                    pass
    if candidates:
        return round(max(candidates) / 1000)
    return None


def gather_now_playing():
    state = {"player": "", "status": "Stopped", "title": "", "artist": "",
             "album": ""}
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        dbus = Gio.DBusProxy.new_sync(
            bus, Gio.DBusProxyFlags.NONE, None,
            "org.freedesktop.DBus", "/org/freedesktop/DBus",
            "org.freedesktop.DBus", None,
        )
        names_v = dbus.call_sync(
            "ListNames", None, Gio.DBusCallFlags.NONE, 800, None,
        )
        names = names_v.unpack()[0]
    except (GLib.Error, Exception):
        return state

    players = [n for n in names if n.startswith("org.mpris.MediaPlayer2.")]
    if not players:
        return state

    candidates = []
    for name in players:
        try:
            p = Gio.DBusProxy.new_sync(
                bus, Gio.DBusProxyFlags.NONE, None,
                name, "/org/mpris/MediaPlayer2",
                "org.freedesktop.DBus.Properties", None,
            )
            status = p.call_sync(
                "Get",
                GLib.Variant("(ss)",
                             ("org.mpris.MediaPlayer2.Player",
                              "PlaybackStatus")),
                Gio.DBusCallFlags.NONE, 800, None,
            ).unpack()[0]
            meta = p.call_sync(
                "Get",
                GLib.Variant("(ss)",
                             ("org.mpris.MediaPlayer2.Player", "Metadata")),
                Gio.DBusCallFlags.NONE, 800, None,
            ).unpack()[0]
        except (GLib.Error, Exception):
            continue
        candidates.append((status, name, meta))

    order = {"Playing": 0, "Paused": 1, "Stopped": 2}
    candidates.sort(key=lambda c: order.get(c[0], 3))
    if not candidates:
        return state
    status, name, meta = candidates[0]
    state["status"] = status
    state["player"] = name.rsplit(".", 1)[-1]
    state["title"] = meta.get("xesam:title", "") or ""
    artists = meta.get("xesam:artist") or []
    if isinstance(artists, list):
        state["artist"] = ", ".join(artists)
    else:
        state["artist"] = str(artists)
    state["album"] = meta.get("xesam:album", "") or ""
    state["art_url"] = meta.get("mpris:artUrl", "") or ""
    return state


def gather_active_theme():
    path = os.path.expanduser("~/nix/home/theme/active.nix")
    try:
        with open(path) as f:
            content = f.read()
    except OSError:
        return ""
    m = re.search(r"./themes/([a-z0-9-]+)\.nix", content)
    return m.group(1) if m else ""


def gather_keep_awake():
    # Reads the inhibit process owned by the action module; True if the
    # systemd-inhibit child we spawned is still alive.
    proc = actions._inhibit_proc
    if proc is not None and proc.poll() is None:
        return True
    actions._inhibit_proc = None
    return False


def gather_night_light():
    out, ok = _run(["pgrep", "-x", "wlsunset"])
    return ok and bool(out.strip())


def _default_state():
    now = time.localtime()
    return {
        "time": f"{now.tm_hour:02d}:{now.tm_min:02d}",
        "hostname": os.uname().nodename if hasattr(os, "uname") else "",
        "caps": capabilities(),
        "wifi": {
            "enabled": False, "connected": False, "ssid": None,
            "signal_pct": 0, "band": "", "freq_mhz": 0,
            "security": "", "ip": "", "gateway": "", "networks": [],
        },
        "bluetooth": {"powered": False, "devices": [], "primary": None},
        "audio": {
            "sink_volume_pct": 0, "sink_muted": False, "sink_name": "—",
            "source_volume_pct": 0, "source_muted": False, "source_name": "—",
            "sinks": [], "sources": [],
        },
        "battery": {"percent": 0, "status": "Unknown", "charging": False, "time_str": "—"},
        "brightness": {"percent": 100},
        "power_profile": "balanced",
        "dnd": {"mode": "default", "enabled": False},
        "tailscale": {
            "enabled": False, "ip": "", "name": "", "os": "",
            "peers": [], "peer_count": 0, "exit_node": "None",
        },
        "mullvad": {"connected": False, "location": "—", "country": "", "city": "", "preferred": ""},
        "cpu_temp": None,
        "now_playing": {"player": "", "status": "Stopped", "title": "",
                        "artist": "", "album": "", "art_url": ""},
        "active_theme": gather_active_theme(),
        "keep_awake": gather_keep_awake(),
        "night_light": gather_night_light(),
    }




def gather_fast_state(previous=None):
    """Fast, visible state refreshed often without waiting on network/VPN calls."""
    previous = previous or _default_state()
    now = time.localtime()
    return {
        **previous,
        "time": f"{now.tm_hour:02d}:{now.tm_min:02d}",
        "hostname": os.uname().nodename if hasattr(os, "uname") else "",
        "audio": gather_audio(),
        "battery": gather_battery(),
        "brightness": gather_brightness(),
        "power_profile": gather_power_profile(),
        "dnd": gather_dnd(),
        "cpu_temp": gather_cpu_temp(),
        "now_playing": gather_now_playing(),
        "active_theme": gather_active_theme(),
        "keep_awake": gather_keep_awake(),
        "night_light": gather_night_light(),
    }


def gather_slow_state(previous=None):
    """Slower subsystems that should not hold up initial paint or audio UI."""
    previous = previous or _default_state()
    return {
        **previous,
        "wifi": gather_wifi(),
        "bluetooth": gather_bluetooth(),
        "tailscale": gather_tailscale(),
        "mullvad": gather_mullvad(),
    }
