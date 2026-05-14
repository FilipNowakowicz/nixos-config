#!/usr/bin/env python3
"""Control Center — unified system panel.

Step 1 scaffold: full layout with mocked data, working navigation,
theme-aware styling. Live data sources are wired in a later step.
"""

import ctypes
import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from types import SimpleNamespace

os.environ["GDK_BACKEND"] = "wayland"

_gls = os.environ.get("GTK4_LAYER_SHELL_LIB", "")
if _gls:
    ctypes.CDLL(_gls, mode=ctypes.RTLD_GLOBAL)

import gi

gi.require_version("Gtk4LayerShell", "1.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, Gio, GLib, Gtk, Gtk4LayerShell


STATE_PATH = "/tmp/control-center.json"
LOCK_PATH = "/tmp/control-center.lock"
_lock_fd = None
_inhibit_proc = None
_location_cache = None   # (lat, lon) once resolved
_location_lock = threading.Lock()

VIEWS = ("home", "wifi", "bluetooth", "vpn", "dnd", "volume", "microphone")

DEFAULTS = {
    "bg": "161a20",
    "brown": "1f252d",
    "orange": "4a5568",
    "amber": "8aa4b8",
    "text": "c8d0d8",
}

# Nerd Font glyphs — system already ships JetBrainsMono Nerd Font,
# so we use codepoints rather than embedded SVG.
G = {
    "wifi": "󰤨",
    "wifi_3": "󰤥",
    "wifi_2": "󰤢",
    "wifi_1": "󰤟",
    "bluetooth": "󰂯",
    "bluetooth_on": "󰂱",
    "shield": "󰒃",
    "bell_off": "󰂛",
    "coffee": "󰛊",
    "volume": "󰕾",
    "volume_mute": "󰝟",
    "mic": "󰍬",
    "mic_off": "󰍭",
    "sun": "󰃟",
    "moon": "󰽢",
    "palette": "󰏘",
    "settings": "󰒓",
    "lock": "󰌾",
    "power": "󰐥",
    "sleep": "󰒲",
    "leaf": "󰌪",
    "gauge": "󰂀",
    "zap": "󱐋",
    "globe": "󰖟",
    "key": "󰌆",
    "chevron_left": "",
    "chevron_right": "",
    "headphones": "󰋋",
    "mouse": "󰍽",
    "keyboard": "󰌌",
    "laptop": "󰌢",
    "server": "󰒋",
    "phone": "󰏲",
    "monitor": "󰍹",
    "clock": "󰥔",
    "plus": "",
    "play": "󰐊",
    "pause": "󰏤",
    "skip_back": "󰒮",
    "skip_forward": "󰒭",
    "live_dot": "●",
}


# ── Lock / state ─────────────────────────────────────────────────


def acquire_lock():
    global _lock_fd
    _lock_fd = open(LOCK_PATH, "w")
    fcntl.flock(_lock_fd, fcntl.LOCK_EX)


def release_lock():
    global _lock_fd
    if _lock_fd is not None:
        fcntl.flock(_lock_fd, fcntl.LOCK_UN)
        _lock_fd.close()
        _lock_fd = None


def read_state():
    try:
        with open(STATE_PATH) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def write_state(pid, view):
    with open(STATE_PATH, "w") as f:
        json.dump({"pid": pid, "view": view}, f)


def clear_state(expected_pid):
    state = read_state()
    if state.get("pid") == expected_pid:
        try:
            os.unlink(STATE_PATH)
        except OSError:
            pass


def process_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


# ── Colors ───────────────────────────────────────────────────────


def load_colors():
    colors = dict(DEFAULTS)
    path = os.path.expanduser("~/.config/waybar/colors.css")
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r"@define-color\s+(\w+)\s+#([0-9a-fA-F]{6})", line)
                if m:
                    colors[m.group(1)] = m.group(2)
    except OSError:
        pass
    return colors


def h2rgb(h):
    return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))


# ── State gathering ──────────────────────────────────────────────


def _run(cmd, timeout=1.5):
    """Run a command, return (stdout, ok)."""
    try:
        r = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        )
        return r.stdout, r.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return "", False


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
    global _inhibit_proc
    if _inhibit_proc is not None and _inhibit_proc.poll() is None:
        return True
    _inhibit_proc = None
    return False


def gather_night_light():
    out, ok = _run(["pgrep", "-x", "wlsunset"])
    return ok and bool(out.strip())


def gather_state():
    now = time.localtime()
    return {
        "time": f"{now.tm_hour:02d}:{now.tm_min:02d}",
        "hostname": os.uname().nodename if hasattr(os, "uname") else "",
        "wifi": gather_wifi(),
        "bluetooth": gather_bluetooth(),
        "audio": gather_audio(),
        "battery": gather_battery(),
        "brightness": gather_brightness(),
        "power_profile": gather_power_profile(),
        "dnd": gather_dnd(),
        "tailscale": gather_tailscale(),
        "mullvad": gather_mullvad(),
        "cpu_temp": gather_cpu_temp(),
        "now_playing": gather_now_playing(),
        "active_theme": gather_active_theme(),
        "keep_awake": gather_keep_awake(),
        "night_light": gather_night_light(),
    }


# ── Actions (write paths) ────────────────────────────────────────


def _fire(cmd):
    """Spawn a write command without blocking. Errors swallowed; the next
    poll tick reconciles visual state with reality."""
    try:
        subprocess.Popen(
            cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except (OSError, FileNotFoundError):
        pass


def act_set_sink_volume(pct):
    _fire(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@",
           f"{max(0, min(100, int(pct)))/100:.2f}"])


def act_set_source_volume(pct):
    _fire(["wpctl", "set-volume", "@DEFAULT_AUDIO_SOURCE@",
           f"{max(0, min(100, int(pct)))/100:.2f}"])


def act_set_brightness(pct):
    _fire(["brightnessctl", "set", f"{max(1, min(100, int(pct)))}%"])


def act_toggle_sink_mute():
    _fire(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])


def act_toggle_source_mute():
    _fire(["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"])


def act_set_default_sink(sink_id):
    _fire(["wpctl", "set-default", str(sink_id)])


def act_set_default_source(source_id):
    _fire(["wpctl", "set-default", str(source_id)])


def act_set_power_profile(name):
    _fire(["powerprofilesctl", "set", name])


def act_set_dnd_mode(mode):
    _fire(["makoctl", "mode", "-s", mode])


def act_set_wifi_radio(on):
    _fire(["nmcli", "radio", "wifi", "on" if on else "off"])


def act_connect_wifi(ssid):
    _fire(["nmcli", "dev", "wifi", "connect", ssid])


def act_bt_powered(on):
    _fire(["bluetoothctl", "power", "on" if on else "off"])


def act_bt_connect(addr):
    _fire(["bluetoothctl", "connect", addr])


def act_bt_disconnect(addr):
    _fire(["bluetoothctl", "disconnect", addr])


def act_tailscale_up(extra=None):
    cmd = ["tailscale", "up"]
    if extra:
        cmd.extend(extra)
    _fire(cmd)


def act_tailscale_down():
    _fire(["tailscale", "down"])


def act_tailscale_exit_node(name):
    """Set or clear the exit node."""
    arg = f"--exit-node={name}" if name else "--exit-node="
    _fire(["tailscale", "up", arg])


def act_mullvad_connect():
    _fire(["mullvad", "connect"])


def act_mullvad_disconnect():
    _fire(["mullvad", "disconnect"])


def act_mullvad_set_location(loc):
    """loc is whitespace-separated like 'se' or 'se sto' or 'se sto se-sto-wg-001'."""
    _fire(["mullvad", "relay", "set", "location"] + loc.split())


def act_switch_theme(name):
    script = os.path.expanduser("~/nix/home/files/scripts/theme-switch.sh")
    _fire(["bash", script, name])


def act_lock():
    _fire(["hyprlock"])


def act_suspend():
    _fire(["systemctl", "suspend"])


def act_poweroff():
    _fire(["systemctl", "poweroff"])


def act_mpris(player, method):
    """Fire a Player method on org.mpris.MediaPlayer2.<player>."""
    if not player:
        return
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        proxy = Gio.DBusProxy.new_sync(
            bus, Gio.DBusProxyFlags.NONE, None,
            f"org.mpris.MediaPlayer2.{player}",
            "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player", None,
        )
        proxy.call_sync(method, None, Gio.DBusCallFlags.NONE, 500, None)
    except (GLib.Error, Exception):
        pass


def act_keep_awake(on):
    global _inhibit_proc
    if on:
        if _inhibit_proc is None or _inhibit_proc.poll() is not None:
            try:
                _inhibit_proc = subprocess.Popen(
                    ["systemd-inhibit", "--what=idle:sleep",
                     "--who=Control Center", "--why=Keep Awake",
                     "--mode=block", "sleep", "infinity"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
            except (OSError, FileNotFoundError):
                pass
    else:
        if _inhibit_proc is not None:
            _inhibit_proc.terminate()
            _inhibit_proc = None


def _resolve_location():
    """Return (lat, lon) from IP geolocation, with in-process cache."""
    global _location_cache
    with _location_lock:
        if _location_cache is not None:
            return _location_cache
    try:
        out, ok = _run(
            ["curl", "-sf", "--max-time", "3", "http://ip-api.com/json"],
            timeout=4,
        )
        if ok:
            data = json.loads(out)
            lat, lon = data["lat"], data["lon"]
            with _location_lock:
                _location_cache = (lat, lon)
            return _location_cache
    except Exception:
        pass
    return (52.2, 21.0)  # fallback: Warsaw


def act_night_light(on):
    if on:
        def _start():
            lat, lon = _resolve_location()
            _fire(["wlsunset", "-l", str(lat), "-L", str(lon)])
        threading.Thread(target=_start, daemon=True).start()
    else:
        _fire(["pkill", "wlsunset"])


# ── Application ──────────────────────────────────────────────────


class ControlCenter(Gtk.Application):
    POLL_MS = 1500
    PENDING_TTL_S = 6

    def __init__(self, initial_view, colors, state):
        super().__init__(application_id="io.personal.control-center")
        self.initial_view = initial_view
        self.colors = colors
        self.state = state
        self.win = None
        self.stack = None
        self._refreshers = []
        self._poll_id = 0
        # Optimistic overrides while slow writes (e.g. tailscale up) catch up.
        # key -> (target_value, expires_at)
        self._pending = {}
        self.connect("activate", self._build)
        self.connect("shutdown", self._on_shutdown)

    # ── Window + stack ────────────────────────────────────────

    def _build(self, _app):
        provider = Gtk.CssProvider()
        provider.load_from_data(self._css().encode())
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

        self.win = Gtk.ApplicationWindow(application=self)
        self.win.set_decorated(False)
        self.win.set_resizable(False)
        self.win.connect("close-request", self._on_close_request)

        Gtk4LayerShell.init_for_window(self.win)
        Gtk4LayerShell.set_layer(self.win, Gtk4LayerShell.Layer.OVERLAY)
        Gtk4LayerShell.set_anchor(self.win, Gtk4LayerShell.Edge.TOP, True)
        Gtk4LayerShell.set_anchor(self.win, Gtk4LayerShell.Edge.RIGHT, True)
        Gtk4LayerShell.set_margin(self.win, Gtk4LayerShell.Edge.TOP, 62)
        Gtk4LayerShell.set_margin(self.win, Gtk4LayerShell.Edge.RIGHT, 15)
        Gtk4LayerShell.set_keyboard_mode(
            self.win, Gtk4LayerShell.KeyboardMode.ON_DEMAND
        )
        Gtk4LayerShell.set_namespace(self.win, "control-center")

        key = Gtk.EventControllerKey()
        key.connect("key-pressed", self._on_key)
        self.win.add_controller(key)

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT)
        self.stack.set_transition_duration(260)
        self.stack.set_size_request(400, -1)

        self.stack.add_named(self._build_home_view(), "home")
        self.stack.add_named(self._build_wifi_view(), "wifi")
        self.stack.add_named(self._build_bluetooth_view(), "bluetooth")
        self.stack.add_named(self._build_vpn_view(), "vpn")
        self.stack.add_named(self._build_dnd_view(), "dnd")
        self.stack.add_named(self._build_volume_view(), "volume")
        self.stack.add_named(self._build_microphone_view(), "microphone")
        self.stack.set_visible_child_name(self.initial_view)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        outer.set_name("panel")
        outer.append(self.stack)

        self.win.set_child(outer)
        self.win.present()

        # Kick off polling. Initial state is already rendered by builders.
        self._poll_id = GLib.timeout_add(self.POLL_MS, self._tick)

    def _on_close_request(self, *_args):
        clear_state(os.getpid())
        return False

    def _on_shutdown(self, *_args):
        if self._poll_id:
            GLib.source_remove(self._poll_id)
            self._poll_id = 0

    def _on_key(self, _ctrl, keyval, _keycode, _state):
        if keyval == Gdk.KEY_Escape:
            if self.stack.get_visible_child_name() != "home":
                self.go_back()
                return True
            self.quit()
            return True
        return False

    # ── Refresh loop ──────────────────────────────────────────

    def _tick(self):
        try:
            self.state = gather_state()
        except Exception:
            return True
        for fn in self._refreshers:
            try:
                fn(self.state)
            except Exception:
                pass
        return True

    @staticmethod
    def _set_class(widget, klass, on):
        if on:
            if not widget.has_css_class(klass):
                widget.add_css_class(klass)
        else:
            if widget.has_css_class(klass):
                widget.remove_css_class(klass)

    @staticmethod
    def _clear(container):
        child = container.get_first_child()
        while child:
            nxt = child.get_next_sibling()
            container.remove(child)
            child = nxt

    # ── Pending overrides for slow writes ─────────────────────

    def _pending_set(self, key, target, ttl_s=None):
        self._pending[key] = (
            target, time.time() + (ttl_s or self.PENDING_TTL_S),
        )

    def effective(self, key, polled):
        """Return the user-intended value if a pending write is in flight
        and hasn't yet been observed in the polled state; otherwise polled."""
        entry = self._pending.get(key)
        if entry is None:
            return polled
        target, expires_at = entry
        if time.time() > expires_at:
            del self._pending[key]
            return polled
        if polled == target:
            del self._pending[key]
            return polled
        return target

    # ── Slider drag/click/scroll binding ──────────────────────

    def _bind_slider(self, slider, on_set):
        """Wire a slider SimpleNamespace to user input. on_set(pct) called
        on click/drag/scroll. Refresh ticks should call _set_slider_polled
        instead of _set_slider so they skip during active drags."""
        track = slider.fill.get_parent()
        track.set_can_target(True)
        slider._dragging = False
        slider._last_pct = -1

        def pos_to_pct(x):
            w = track.get_width()
            if w <= 0:
                return None
            return max(0, min(100, round(x / w * 100)))

        last = {"t": 0.0}

        def fire(pct, force=False):
            if pct is None:
                return
            now = time.monotonic()
            if not force and pct == slider._last_pct and now - last["t"] < 0.08:
                return  # throttle drag-update spam
            last["t"] = now
            slider._last_pct = pct
            self._set_slider(slider, pct)
            on_set(pct)

        click = Gtk.GestureClick()

        def on_released(_g, _n, x, _y):
            fire(pos_to_pct(x), force=True)
        click.connect("released", on_released)
        track.add_controller(click)

        drag = Gtk.GestureDrag()
        ds = {"base_x": 0.0}

        def on_begin(_g, sx, _sy):
            slider._dragging = True
            ds["base_x"] = sx
            fire(pos_to_pct(sx), force=True)

        def on_update(_g, ox, _oy):
            fire(pos_to_pct(ds["base_x"] + ox))

        def on_end(_g, ox, _oy):
            fire(pos_to_pct(ds["base_x"] + ox), force=True)

            def _release(_sl=slider):
                _sl._dragging = False
                return False
            GLib.timeout_add(200, _release)
        drag.connect("drag-begin", on_begin)
        drag.connect("drag-update", on_update)
        drag.connect("drag-end", on_end)
        track.add_controller(drag)

        scroll = Gtk.EventControllerScroll.new(
            Gtk.EventControllerScrollFlags.VERTICAL,
        )

        def on_scroll(_c, _dx, dy):
            cur = slider._last_pct
            if cur < 0:
                try:
                    cur = int(slider.value.get_label() or "0")
                except ValueError:
                    cur = 0
            step = 5
            # Negative dy = wheel up = increase
            new = max(0, min(100, cur - int(dy) * step))
            fire(new, force=True)
            return True
        scroll.connect("scroll", on_scroll)
        slider.widget.add_controller(scroll)

    def _set_slider_polled(self, slider, pct):
        """Variant of _set_slider that skips when user is dragging."""
        if getattr(slider, "_dragging", False):
            return
        self._set_slider(slider, pct)
        slider._last_pct = int(pct)

    # ── Navigation ────────────────────────────────────────────

    def go_to(self, view):
        self.stack.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT)
        self.stack.set_visible_child_name(view)

    def go_back(self):
        self.stack.set_transition_type(Gtk.StackTransitionType.SLIDE_RIGHT)
        self.stack.set_visible_child_name("home")

    # ── Reusable component builders ───────────────────────────

    @staticmethod
    def _label(text, css=None, xalign=0):
        lbl = Gtk.Label(label=text, xalign=xalign)
        if css:
            for c in css if isinstance(css, (list, tuple)) else (css,):
                lbl.add_css_class(c)
        return lbl

    @staticmethod
    def _box(orientation=Gtk.Orientation.VERTICAL, spacing=0, css=None):
        box = Gtk.Box(orientation=orientation, spacing=spacing)
        if css:
            for c in css if isinstance(css, (list, tuple)) else (css,):
                box.add_css_class(c)
        return box

    def _section_label(self, text, action=None, action_cb=None):
        row = self._box(Gtk.Orientation.HORIZONTAL, css="section-label")
        row.append(self._label(text, "section-text"))
        row.append(Gtk.Box(hexpand=True))
        if action:
            btn = Gtk.Button(label=action)
            btn.add_css_class("section-action")
            if action_cb:
                btn.connect("clicked", lambda _b: action_cb())
            row.append(btn)
        return row

    def _switch(self, css=None):
        """Visual switch. Toggle .on class via _set_class()."""
        sw = Gtk.Button()
        sw.add_css_class("switch")
        if css:
            for c in css if isinstance(css, (list, tuple)) else (css,):
                sw.add_css_class(c)
        knob = Gtk.Box()
        knob.add_css_class("switch-knob")
        sw.set_child(knob)
        return sw

    @staticmethod
    def _toggle_class(widget, klass):
        if widget.has_css_class(klass):
            widget.remove_css_class(klass)
        else:
            widget.add_css_class(klass)

    def _tile(self, title, view=None):
        """Build a tile and return a SimpleNamespace of refs."""
        btn = Gtk.Button()
        btn.add_css_class("tile")

        inner = self._box(Gtk.Orientation.VERTICAL, spacing=4)
        top = self._box(Gtk.Orientation.HORIZONTAL, css="tile-icon")
        glyph_lbl = self._label("", "tile-glyph")
        top.append(glyph_lbl)
        top.append(Gtk.Box(hexpand=True))
        badge_lbl = self._label("", "tile-badge")
        badge_lbl.set_visible(False)
        top.append(badge_lbl)
        chevron = self._label(G["chevron_right"], "tile-chevron")
        top.append(chevron)
        inner.append(top)
        title_lbl = self._label(title, "tile-title")
        sub_lbl = self._label("", "tile-sub")
        inner.append(title_lbl)
        inner.append(sub_lbl)
        btn.set_child(inner)

        if view:
            btn.connect("clicked", lambda _b, v=view: self.go_to(v))
        return SimpleNamespace(
            widget=btn, glyph=glyph_lbl, title=title_lbl,
            sub=sub_lbl, badge=badge_lbl,
        )

    def _slider_row(self, glyph, aux_label=None, aux_view=None):
        """Build a slider row. Returns SimpleNamespace(widget, fill, value, aux)."""
        row = self._box(Gtk.Orientation.HORIZONTAL, spacing=12, css="slider-row")

        gbtn = Gtk.Button(label=glyph)
        gbtn.add_css_class("glyph-btn")
        row.append(gbtn)

        track = Gtk.Box()
        track.add_css_class("slider-track")
        track.set_hexpand(True)
        fill = Gtk.Box()
        fill.add_css_class("slider-fill")
        fill.set_size_request(0, -1)
        knob = Gtk.Box()
        knob.add_css_class("slider-knob")
        fill.append(knob)
        track.append(fill)
        row.append(track)

        val = self._label("0", "slider-value", xalign=1)
        val.set_width_chars(3)
        row.append(val)

        aux = None
        if aux_label:
            aux = Gtk.Button(label=aux_label)
            aux.add_css_class("slider-aux")
            if aux_view:
                aux.connect("clicked", lambda _b, v=aux_view: self.go_to(v))
            row.append(aux)

        return SimpleNamespace(
            widget=row, glyph_btn=gbtn, fill=fill, value=val, aux=aux,
        )

    def _set_slider(self, slider, pct):
        slider.fill.set_size_request(max(0, min(100, int(pct))) * 3, -1)
        slider.value.set_label(str(int(pct)))

    @staticmethod
    def _short(name, n=22):
        if not name:
            return "—"
        return name if len(name) <= n else name[: n - 1] + "…"

    @staticmethod
    def _wifi_glyph(signal_pct):
        if signal_pct >= 70:
            return G["wifi"]
        if signal_pct >= 50:
            return G["wifi_3"]
        if signal_pct >= 30:
            return G["wifi_2"]
        return G["wifi_1"]

    @staticmethod
    def _bt_icon_glyph(icon_hint):
        h = (icon_hint or "").lower()
        if "headset" in h or "headphone" in h or "audio" in h:
            return G["headphones"]
        if "mouse" in h or "pointing" in h:
            return G["mouse"]
        if "keyboard" in h or "input-keyboard" in h:
            return G["keyboard"]
        if "phone" in h:
            return G["phone"]
        return G["bluetooth"]

    @staticmethod
    def _sink_icon_glyph(desc):
        d = (desc or "").lower()
        if "hdmi" in d or "displayport" in d:
            return G["monitor"]
        if "bluetooth" in d or "buds" in d or "headph" in d or "wh-" in d:
            return G["headphones"]
        return G["volume"]

    @staticmethod
    def _country_code(name):
        if not name:
            return "—"
        table = {
            "united kingdom": "GB", "uk": "GB", "great britain": "GB",
            "united states": "US", "usa": "US", "u.s.a.": "US",
            "sweden": "SE", "germany": "DE", "switzerland": "CH",
            "netherlands": "NL", "france": "FR", "norway": "NO",
            "denmark": "DK", "finland": "FI", "poland": "PL",
            "spain": "ES", "italy": "IT", "ireland": "IE", "canada": "CA",
            "japan": "JP", "australia": "AU", "austria": "AT",
            "belgium": "BE", "czech republic": "CZ", "czechia": "CZ",
        }
        return table.get(name.strip().lower(), name[:2].upper())

    def _chip(self, glyph, label, on=False, css=None):
        btn = Gtk.Button()
        btn.add_css_class("chip")
        if on:
            btn.add_css_class("on")
        if css:
            for c in css if isinstance(css, (list, tuple)) else (css,):
                btn.add_css_class(c)
        inner = self._box(Gtk.Orientation.HORIZONTAL, spacing=6)
        inner.append(self._label(glyph, "chip-glyph"))
        inner.append(self._label(label))
        btn.set_child(inner)
        btn.connect("clicked", lambda b: self._toggle_class(b, "on"))
        return btn

    def _segmented(self, options, active_idx=-1, click_visual=False):
        """options: list of (glyph, label) tuples.

        Returns SimpleNamespace(widget, buttons). If click_visual is True,
        clicking a segment flips its visual active state locally — used for
        sections that don't have backing state (DND timers). For state-bound
        segments (power profile), leave click_visual False so the periodic
        refresh stays the source of truth.
        """
        bar = self._box(Gtk.Orientation.HORIZONTAL, spacing=2, css="segmented")
        buttons = []

        def select(idx):
            for i, btn in enumerate(buttons):
                if i == idx:
                    btn.add_css_class("active")
                else:
                    btn.remove_css_class("active")

        for i, (glyph, label) in enumerate(options):
            btn = Gtk.Button()
            btn.add_css_class("seg")
            if i == active_idx:
                btn.add_css_class("active")
            btn.set_hexpand(True)
            inner = self._box(Gtk.Orientation.HORIZONTAL, spacing=6)
            inner.append(self._label(glyph))
            inner.append(self._label(label))
            btn.set_child(inner)
            if click_visual:
                btn.connect("clicked", lambda _b, idx=i: select(idx))
            buttons.append(btn)
            bar.append(btn)
        return SimpleNamespace(widget=bar, buttons=buttons)

    def _drawer_item(self, glyph, name, subtitle, right_text,
                     active=False, subtle=False, status=None):
        """status: None / "online" / "this" / "offline" """
        btn = Gtk.Button()
        btn.add_css_class("drawer-item")
        if active:
            btn.add_css_class("active")
        if subtle:
            btn.add_css_class("subtle")

        row = self._box(Gtk.Orientation.HORIZONTAL, spacing=10)

        icon = self._label(glyph, "di-icon")
        icon.set_width_chars(2)
        row.append(icon)

        copy = self._box(Gtk.Orientation.VERTICAL, spacing=2)
        copy.set_hexpand(True)
        copy.append(self._label(name, "di-name"))
        if subtitle:
            copy.append(self._label(subtitle, "di-sub"))
        row.append(copy)

        right = self._box(Gtk.Orientation.HORIZONTAL, spacing=6, css="di-right")
        if status:
            dot = Gtk.Box()
            dot.add_css_class("status-dot")
            dot.add_css_class(status)
            right.append(dot)
        right.append(self._label(right_text))
        row.append(right)

        btn.set_child(row)
        return btn

    def _drawer_row(self, glyph, name, subtitle, control_widget):
        row = self._box(Gtk.Orientation.HORIZONTAL, spacing=10, css="drawer-row")
        icon = self._label(glyph, "di-icon")
        icon.set_width_chars(2)
        row.append(icon)
        copy = self._box(Gtk.Orientation.VERTICAL, spacing=2)
        copy.set_hexpand(True)
        copy.append(self._label(name, "di-name"))
        if subtitle:
            copy.append(self._label(subtitle, "di-sub"))
        row.append(copy)
        row.append(control_widget)
        return row

    def _drawer_select(self, label):
        btn = Gtk.Button()
        btn.add_css_class("drawer-select")
        inner = self._box(Gtk.Orientation.HORIZONTAL, spacing=6)
        inner.append(self._label(label))
        inner.append(self._label(G["chevron_right"]))
        btn.set_child(inner)
        return btn

    def _ghost_btn(self, label):
        btn = Gtk.Button(label=label)
        btn.add_css_class("ghost-btn")
        return btn

    def _icon_btn(self, glyph, danger=False):
        btn = Gtk.Button(label=glyph)
        btn.add_css_class("icon-btn")
        if danger:
            btn.add_css_class("danger")
        return btn

    def _detail_header(self, title, meta=None, right_widget=None):
        row = self._box(Gtk.Orientation.HORIZONTAL, spacing=8, css="panel-header")
        back = Gtk.Button(label=G["chevron_left"])
        back.add_css_class("back-btn")
        back.connect("clicked", lambda _b: self.go_back())
        row.append(back)
        row.append(self._label(title, ["panel-title", "with-back"]))
        row.append(Gtk.Box(hexpand=True))
        if right_widget is not None:
            row.append(right_widget)
        elif meta:
            row.append(self._label(meta, "panel-meta", xalign=1))
        return row

    def _hero_card_ref(self):
        """Hero card with ref-able sub-widgets. Populate via the returned NS."""
        card = self._box(Gtk.Orientation.HORIZONTAL, spacing=14, css="hero-card")
        icon = self._label("", "hero-icon-wrap")
        icon.set_width_chars(3)
        card.append(icon)
        copy = self._box(Gtk.Orientation.VERTICAL, spacing=2)
        copy.set_hexpand(True)
        title = self._label("", "hero-title")
        sub = self._label("", "hero-sub")
        copy.append(title)
        copy.append(sub)
        card.append(copy)
        meta_box = self._box(Gtk.Orientation.VERTICAL, css="hero-meta")
        big = self._label("", "hero-big", xalign=1)
        small = self._label("", "hero-small", xalign=1)
        meta_box.append(big)
        meta_box.append(small)
        card.append(meta_box)
        return SimpleNamespace(
            widget=card, icon=icon, title=title, sub=sub, big=big, small=small,
        )

    def _fill_stat_grid(self, bar, cells):
        """Clear and re-populate a stat strip Grid with (value, label) cells."""
        self._clear(bar)
        for i, (value, label) in enumerate(cells):
            cell = self._box(Gtk.Orientation.VERTICAL, css="vpn-stat-cell")
            cell.append(self._label(value, "vpn-stat-value", xalign=0.5))
            cell.append(self._label(label, "vpn-stat-label", xalign=0.5))
            bar.attach(cell, i, 0, 1, 1)

    # ── View: Home ────────────────────────────────────────────

    def _build_home_view(self):
        view = self._box(Gtk.Orientation.VERTICAL, spacing=12, css="panel-stack")

        # Header
        header = self._box(Gtk.Orientation.HORIZONTAL, css="panel-header")
        title = self._box(Gtk.Orientation.HORIZONTAL, spacing=8, css="panel-title")
        live = self._label(G["live_dot"], "live-dot")
        title.append(live)
        title.append(self._label("Control Center"))
        header.append(title)
        header.append(Gtk.Box(hexpand=True))
        meta = self._label("", "panel-meta", xalign=1)
        header.append(meta)
        view.append(header)

        # Tile grid 2×2
        wifi_t = self._tile("Wi-Fi", view="wifi")
        bt_t = self._tile("Bluetooth", view="bluetooth")
        vpn_t = self._tile("VPN", view="vpn")
        dnd_t = self._tile("Do Not Disturb", view="dnd")

        grid = Gtk.Grid(
            column_homogeneous=True, column_spacing=8, row_spacing=8
        )
        grid.add_css_class("tile-grid")
        grid.attach(wifi_t.widget, 0, 0, 1, 1)
        grid.attach(bt_t.widget, 1, 0, 1, 1)
        grid.attach(vpn_t.widget, 0, 1, 1, 1)
        grid.attach(dnd_t.widget, 1, 1, 1, 1)
        view.append(grid)

        # Sliders
        vol_s = self._slider_row(
            G["volume"], aux_label="Speakers ›", aux_view="volume",
        )
        brt_s = self._slider_row(G["sun"], aux_label="Auto")
        mic_s = self._slider_row(
            G["mic"], aux_label="Internal ›", aux_view="microphone",
        )
        sliders = self._box(
            Gtk.Orientation.VERTICAL, spacing=12,
            css=["surface", "slider-block"],
        )
        sliders.append(vol_s.widget)
        sliders.append(brt_s.widget)
        sliders.append(mic_s.widget)
        view.append(sliders)

        self._bind_slider(vol_s, act_set_sink_volume)
        self._bind_slider(brt_s, act_set_brightness)
        self._bind_slider(mic_s, act_set_source_volume)
        vol_s.glyph_btn.connect(
            "clicked", lambda _b: act_toggle_sink_mute(),
        )
        mic_s.glyph_btn.connect(
            "clicked", lambda _b: act_toggle_source_mute(),
        )

        # Power profile
        view.append(self._section_label("Power Profile", action="Detailed"))
        pp = self._segmented(
            [(G["leaf"], "Saver"), (G["gauge"], "Balanced"),
             (G["zap"], "Performance")],
        )
        view.append(pp.widget)
        pp_keys = ["power-saver", "balanced", "performance"]

        for key, btn in zip(pp_keys, pp.buttons):
            def _on_pp(_b, k=key):
                self._pending_set("power_profile", k, ttl_s=3)
                # Optimistic visual flip
                for kk, bb in zip(pp_keys, pp.buttons):
                    self._set_class(bb, "active", kk == k)
                act_set_power_profile(k)
            btn.connect("clicked", _on_pp)

        # Quick toggles + theme picker
        view.append(self._section_label("Quick Toggles", action="Edit"))
        chip_row = self._box(Gtk.Orientation.HORIZONTAL, spacing=6, css="chip-row")
        ka_chip = self._chip(G["coffee"], "Keep Awake")
        nl_chip = self._chip(G["moon"], "Night Light")
        theme_chip = self._chip(G["palette"], "Theme", css="theme-trigger")
        chip_row.append(ka_chip)
        chip_row.append(nl_chip)
        chip_row.append(theme_chip)
        view.append(chip_row)

        def _on_keep_awake(b):
            # _chip auto-toggle already flipped .on; read new desired state
            want = b.has_css_class("on")
            self._pending_set("keep_awake", want, ttl_s=4)
            act_keep_awake(want)
        ka_chip.connect("clicked", _on_keep_awake)

        def _on_night_light(b):
            want = b.has_css_class("on")
            self._pending_set("night_light", want, ttl_s=4)
            act_night_light(want)
        nl_chip.connect("clicked", _on_night_light)

        # Theme picker (revealer)
        revealer = Gtk.Revealer()
        revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_DOWN)
        revealer.set_transition_duration(260)
        picker = Gtk.Grid(column_homogeneous=True, column_spacing=6,
                          row_spacing=6)
        picker.add_css_class("theme-picker")
        themes = ["mono-mesh", "desert-dusk", "acid-statue", "nighthawks"]
        theme_cards = {}
        for i, name in enumerate(themes):
            card = Gtk.Button()
            card.add_css_class("theme-card")
            card.add_css_class(f"swatch-{name}")
            inner = self._box(Gtk.Orientation.VERTICAL, spacing=5)
            sw = Gtk.Box()
            sw.add_css_class("theme-swatch")
            sw.add_css_class(f"swatch-{name}")
            inner.append(sw)
            inner.append(self._label(name, "theme-card-name", xalign=0.5))
            card.set_child(inner)
            picker.attach(card, i, 0, 1, 1)
            theme_cards[name] = card

            def _on_theme_pick(_b, n=name):
                # Theme switch triggers a rebuild; can take a few seconds.
                self._pending_set("active_theme", n, ttl_s=20)
                for nn, cc in theme_cards.items():
                    self._set_class(cc, "active-theme", nn == n)
                act_switch_theme(n)
            card.connect("clicked", _on_theme_pick)
        revealer.set_child(picker)
        view.append(revealer)

        def _on_theme(_b):
            opened = not revealer.get_reveal_child()
            revealer.set_reveal_child(opened)
            if opened:
                theme_chip.add_css_class("expanded")
            else:
                theme_chip.remove_css_class("expanded")
        theme_chip.connect("clicked", _on_theme)

        # Now playing
        np_section_lbl = self._label("Now Playing", "section-text")
        np_section_meta = Gtk.Label(label="", xalign=1)
        np_section_meta.add_css_class("section-action")
        np_section_row = self._box(
            Gtk.Orientation.HORIZONTAL, css="section-label",
        )
        np_section_row.append(np_section_lbl)
        np_section_row.append(Gtk.Box(hexpand=True))
        np_section_row.append(np_section_meta)
        view.append(np_section_row)

        np = self._box(Gtk.Orientation.HORIZONTAL, spacing=12, css="nowplaying")
        art = Gtk.Box()
        art.add_css_class("album-art")
        np.append(art)
        track = self._box(Gtk.Orientation.VERTICAL, spacing=2)
        track.set_hexpand(True)
        np_title = self._label("", "np-title")
        np_artist = self._label("", "np-artist")
        track.append(np_title)
        track.append(np_artist)
        np.append(track)
        ctrl = self._box(Gtk.Orientation.HORIZONTAL, spacing=4)
        skip_back_btn = self._icon_btn(G["skip_back"])
        ctrl.append(skip_back_btn)
        play_btn = self._icon_btn(G["play"])
        play_btn.add_css_class("primary")
        ctrl.append(play_btn)
        skip_fwd_btn = self._icon_btn(G["skip_forward"])
        ctrl.append(skip_fwd_btn)
        np.append(ctrl)
        view.append(np)

        skip_back_btn.connect(
            "clicked",
            lambda _b: act_mpris(self.state["now_playing"]["player"], "Previous"),
        )
        play_btn.connect(
            "clicked",
            lambda _b: act_mpris(self.state["now_playing"]["player"], "PlayPause"),
        )
        skip_fwd_btn.connect(
            "clicked",
            lambda _b: act_mpris(self.state["now_playing"]["player"], "Next"),
        )

        # Stat grid (battery, remaining, cpu)
        stats = Gtk.Grid(column_homogeneous=True, column_spacing=6)
        stats.add_css_class("stat-grid")
        bat_cell = self._box(Gtk.Orientation.VERTICAL, css="stat-cell")
        bat_cell.add_css_class("accent")
        bat_value = self._label("", "stat-value", xalign=0.5)
        bat_cell.append(bat_value)
        bat_cell.append(self._label("battery", "stat-label", xalign=0.5))
        stats.attach(bat_cell, 0, 0, 1, 1)

        rem_cell = self._box(Gtk.Orientation.VERTICAL, css="stat-cell")
        rem_value = self._label("", "stat-value", xalign=0.5)
        rem_cell.append(rem_value)
        rem_label = self._label("remaining", "stat-label", xalign=0.5)
        rem_cell.append(rem_label)
        stats.attach(rem_cell, 1, 0, 1, 1)

        cpu_cell = self._box(Gtk.Orientation.VERTICAL, css="stat-cell")
        cpu_value = self._label("", "stat-value", xalign=0.5)
        cpu_cell.append(cpu_value)
        cpu_cell.append(self._label("cpu", "stat-label", xalign=0.5))
        stats.attach(cpu_cell, 2, 0, 1, 1)
        view.append(stats)

        # Action row
        actions = Gtk.Grid(column_homogeneous=True, column_spacing=6)
        actions.add_css_class("action-row")
        lock_btn = self._icon_btn(G["lock"])
        sleep_btn = self._icon_btn(G["sleep"])
        power_btn = self._icon_btn(G["power"], danger=True)
        actions.attach(lock_btn, 0, 0, 1, 1)
        actions.attach(sleep_btn, 1, 0, 1, 1)
        actions.attach(power_btn, 2, 0, 1, 1)
        view.append(actions)

        lock_btn.connect("clicked", lambda _b: (act_lock(), self.quit()))
        sleep_btn.connect("clicked", lambda _b: (self.quit(), act_suspend()))
        power_btn.connect("clicked", lambda _b: (self.quit(), act_poweroff()))

        # ── Refresh ──
        def refresh(s):
            meta.set_label(f"{s.get('hostname', '')} · {s.get('time', '')}")

            # Wi-Fi tile
            w = s["wifi"]
            if not w["enabled"]:
                wifi_t.glyph.set_label(G["wifi"])
                wifi_t.sub.set_label("Off")
                self._set_class(wifi_t.widget, "on", False)
            elif w["connected"] and w["ssid"]:
                wifi_t.glyph.set_label(self._wifi_glyph(w["signal_pct"]))
                band = f" · {w['band']}" if w["band"] else ""
                wifi_t.sub.set_label(self._short(f"{w['ssid']}{band}", 30))
                self._set_class(wifi_t.widget, "on", True)
            else:
                wifi_t.glyph.set_label(G["wifi"])
                wifi_t.sub.set_label("Not connected")
                self._set_class(wifi_t.widget, "on", False)

            # Bluetooth tile
            b = s["bluetooth"]
            if not b["powered"]:
                bt_t.glyph.set_label(G["bluetooth"])
                bt_t.sub.set_label("Off")
                self._set_class(bt_t.widget, "on", False)
            elif b["primary"]:
                bt_t.glyph.set_label(G["bluetooth_on"])
                bat = b["primary"].get("battery")
                bat_s = f" · {bat}%" if bat is not None else ""
                bt_t.sub.set_label(
                    self._short(f"{b['primary']['alias']}{bat_s}", 30)
                )
                self._set_class(bt_t.widget, "on", True)
            else:
                bt_t.glyph.set_label(G["bluetooth_on"])
                n = len(b["devices"])
                bt_t.sub.set_label(f"On · {n} paired")
                self._set_class(bt_t.widget, "on", True)

            # VPN tile
            ts = s["tailscale"]
            mv = s["mullvad"]
            active = (1 if ts["enabled"] else 0) + (1 if mv["connected"] else 0)
            vpn_t.glyph.set_label(G["shield"])
            if ts["enabled"] and ts["ip"]:
                vpn_t.sub.set_label(f"Tailscale · {ts['ip']}")
            elif mv["connected"]:
                vpn_t.sub.set_label(f"Mullvad · {mv['city'] or mv['country']}")
            else:
                vpn_t.sub.set_label("Off")
            self._set_class(vpn_t.widget, "on", active > 0)
            vpn_t.badge.set_label(f"{active}/2")
            vpn_t.badge.set_visible(active > 0)

            # DND tile
            d = s["dnd"]
            dnd_t.glyph.set_label(G["bell_off"])
            if d["enabled"]:
                dnd_t.sub.set_label(f"On · {d['mode']}")
                self._set_class(dnd_t.widget, "on", True)
            else:
                dnd_t.sub.set_label("Off · all notifications")
                self._set_class(dnd_t.widget, "on", False)

            # Sliders
            a = s["audio"]
            self._set_slider_polled(vol_s, a["sink_volume_pct"])
            vol_s.glyph_btn.set_label(
                G["volume_mute"] if a["sink_muted"] else G["volume"]
            )
            if vol_s.aux:
                vol_s.aux.set_label(f"{self._short(a['sink_name'], 14)} ›")
            self._set_slider_polled(brt_s, s["brightness"]["percent"])
            self._set_slider_polled(mic_s, a["source_volume_pct"])
            mic_s.glyph_btn.set_label(
                G["mic_off"] if a["source_muted"] else G["mic"]
            )
            if mic_s.aux:
                mic_s.aux.set_label(f"{self._short(a['source_name'], 14)} ›")

            # Power profile (respect optimistic pending)
            profile = self.effective("power_profile", s["power_profile"])
            for key, btn in zip(pp_keys, pp.buttons):
                self._set_class(btn, "active", key == profile)

            # Quick toggle chips
            self._set_class(
                ka_chip, "on",
                self.effective("keep_awake", s.get("keep_awake", False)),
            )
            self._set_class(
                nl_chip, "on",
                self.effective("night_light", s.get("night_light", False)),
            )

            # Theme cards (pending until rebuild completes)
            active_theme = self.effective("active_theme", s.get("active_theme", ""))
            for name, card in theme_cards.items():
                self._set_class(card, "active-theme", name == active_theme)

            # Now playing
            n = s["now_playing"]
            if n["title"]:
                np_title.set_label(self._short(n["title"], 36))
                parts = [p for p in [n["artist"], n["album"]] if p]
                np_artist.set_label(self._short(" — ".join(parts), 50))
            else:
                np_title.set_label("Nothing playing")
                np_artist.set_label("")
            play_btn.set_label(
                G["pause"] if n["status"] == "Playing" else G["play"]
            )
            np_section_meta.set_label(n["player"] or "")

            # Stats
            bat = s["battery"]
            bat_value.set_label(f"{bat['percent']}%")
            if bat["status"] == "Charging":
                rem_value.set_label(bat["time_str"])
                rem_label.set_label("until full")
            elif bat["status"] == "Full":
                rem_value.set_label("full")
                rem_label.set_label("plugged in")
            else:
                rem_value.set_label(bat["time_str"])
                rem_label.set_label("remaining")
            if s["cpu_temp"] is not None:
                cpu_value.set_label(f"{s['cpu_temp']}°")
            else:
                cpu_value.set_label("—")

        self._refreshers.append(refresh)
        refresh(self.state)
        return view

    # ── View: Wi-Fi ───────────────────────────────────────────

    def _build_wifi_view(self):
        view = self._box(Gtk.Orientation.VERTICAL, spacing=12, css="panel-stack")
        sw = self._switch()
        view.append(self._detail_header("Wi-Fi", right_widget=sw))

        def _on_wifi_toggle(_b):
            current = self.effective(
                "wifi.enabled", self.state["wifi"]["enabled"],
            )
            target = not current
            self._pending_set("wifi.enabled", target, ttl_s=4)
            self._set_class(sw, "on", target)
            act_set_wifi_radio(target)
        sw.connect("clicked", _on_wifi_toggle)

        hero = self._hero_card_ref()
        view.append(hero.widget)
        strip = Gtk.Grid(column_homogeneous=True, column_spacing=6)
        strip.add_css_class("vpn-stat")
        view.append(strip)

        view.append(self._section_label("Available Networks", action="Rescan"))
        lst = self._box(Gtk.Orientation.VERTICAL, spacing=2, css="drawer-list")
        view.append(lst)
        view.append(self._ghost_btn("Open Network Settings"))

        def refresh(s):
            w = s["wifi"]
            enabled = self.effective("wifi.enabled", w["enabled"])
            self._set_class(sw, "on", enabled)

            hero.icon.set_label(self._wifi_glyph(w["signal_pct"]) if w["enabled"] else G["wifi"])
            if w["enabled"] and w["connected"] and w["ssid"]:
                hero.title.set_label(self._short(w["ssid"], 28))
                ip = w["ip"] or "—"
                gw = f" · gw {w['gateway']}" if w["gateway"] else ""
                sec = w["security"] or "—"
                hero.sub.set_label(self._short(f"{sec} · {ip}{gw}", 56))
                hero.big.set_label(f"{w['signal_pct']}")
                hero.small.set_label("signal")
            elif w["enabled"]:
                hero.title.set_label("Not connected")
                hero.sub.set_label("Pick a network below")
                hero.big.set_label("—")
                hero.small.set_label("")
            else:
                hero.title.set_label("Wi-Fi off")
                hero.sub.set_label("Enable to scan")
                hero.big.set_label("—")
                hero.small.set_label("")

            self._fill_stat_grid(strip, [
                (w["band"] or "—", "band"),
                (f"{w['signal_pct']}%" if w["enabled"] else "—", "signal"),
                (f"{w['freq_mhz']}" if w["freq_mhz"] else "—", "MHz"),
            ])

            self._clear(lst)
            if not enabled:
                lst.append(self._drawer_item(
                    G["wifi"], "Wi-Fi disabled",
                    "Toggle the switch above to enable", "—", subtle=True,
                ))
            else:
                shown = 0
                for net in w["networks"]:
                    if net["active"]:
                        continue  # active is in hero
                    if shown >= 6:
                        break
                    parts = [s for s in (net["security"], net["band"]) if s]
                    subtitle = " · ".join(parts) or "—"
                    subtle = net["security"] in ("", "Open", "--")
                    row = self._drawer_item(
                        self._wifi_glyph(net["signal"]),
                        self._short(net["ssid"], 24),
                        subtitle, f"{net['signal']}%",
                        subtle=subtle,
                    )

                    def _on_connect(_b, ssid=net["ssid"]):
                        self._pending_set("wifi.ssid", ssid, ttl_s=10)
                        act_connect_wifi(ssid)
                    row.connect("clicked", _on_connect)
                    lst.append(row)
                    shown += 1
                if shown == 0:
                    lst.append(self._drawer_item(
                        G["wifi"], "No networks", "Try Rescan", "—",
                        subtle=True,
                    ))
                lst.append(self._drawer_item(
                    G["plus"], "Hidden Network", "Join by SSID", "›",
                    subtle=True,
                ))

        self._refreshers.append(refresh)
        refresh(self.state)
        return view

    # ── View: Bluetooth ───────────────────────────────────────

    def _build_bluetooth_view(self):
        view = self._box(Gtk.Orientation.VERTICAL, spacing=12, css="panel-stack")
        sw = self._switch()
        view.append(self._detail_header("Bluetooth", right_widget=sw))

        def _on_bt_toggle(_b):
            target = not self.effective(
                "bluetooth.powered", self.state["bluetooth"]["powered"],
            )
            self._pending_set("bluetooth.powered", target, ttl_s=4)
            self._set_class(sw, "on", target)
            act_bt_powered(target)
        sw.connect("clicked", _on_bt_toggle)

        hero = self._hero_card_ref()
        view.append(hero.widget)
        view.append(self._section_label("My Devices", action="Scan"))
        lst = self._box(Gtk.Orientation.VERTICAL, spacing=2, css="drawer-list")
        view.append(lst)
        view.append(self._ghost_btn("Open Bluetooth Settings"))

        def refresh(s):
            b = s["bluetooth"]
            powered = self.effective("bluetooth.powered", b["powered"])
            self._set_class(sw, "on", powered)

            if b["primary"]:
                p = b["primary"]
                hero.icon.set_label(self._bt_icon_glyph(p.get("icon")))
                hero.title.set_label(self._short(p["alias"], 26))
                addr = p.get("address", "")
                hero.sub.set_label(
                    self._short(f"Connected · {addr}", 56)
                )
                if p.get("battery") is not None:
                    hero.big.set_label(f"{p['battery']}%")
                    hero.small.set_label("battery")
                else:
                    hero.big.set_label("●")
                    hero.small.set_label("active")
            elif not b["powered"]:
                hero.icon.set_label(G["bluetooth"])
                hero.title.set_label("Bluetooth off")
                hero.sub.set_label("Enable to pair devices")
                hero.big.set_label("—")
                hero.small.set_label("")
            else:
                hero.icon.set_label(G["bluetooth_on"])
                hero.title.set_label("No device connected")
                n = len(b["devices"])
                hero.sub.set_label(
                    f"{n} paired device{'s' if n != 1 else ''}"
                )
                hero.big.set_label(str(n))
                hero.small.set_label("paired")

            self._clear(lst)
            if not b["devices"]:
                lst.append(self._drawer_item(
                    G["plus"], "No paired devices",
                    "Put your device in pairing mode", "—",
                    subtle=True,
                ))
            else:
                for d in b["devices"]:
                    bat = d.get("battery")
                    sub_parts = []
                    if d.get("icon"):
                        sub_parts.append(d["icon"].replace("-", " "))
                    if bat is not None:
                        sub_parts.append(f"{bat}%")
                    if not d["connected"]:
                        sub_parts.append("offline")
                    row = self._drawer_item(
                        self._bt_icon_glyph(d.get("icon")),
                        self._short(d["alias"], 24),
                        " · ".join(sub_parts) or "—",
                        "Connected" if d["connected"] else "Connect",
                        active=d["connected"],
                    )

                    def _on_dev_click(_b, addr=d["address"],
                                      currently=d["connected"]):
                        key = f"bluetooth.dev.{addr}"
                        target = not currently
                        self._pending_set(key, target, ttl_s=8)
                        if target:
                            act_bt_connect(addr)
                        else:
                            act_bt_disconnect(addr)
                    row.connect("clicked", _on_dev_click)
                    lst.append(row)
            lst.append(self._drawer_item(
                G["plus"], "Pair new device",
                "Put your device in pairing mode", "›", subtle=True,
            ))

        self._refreshers.append(refresh)
        refresh(self.state)
        return view

    # ── View: VPN ─────────────────────────────────────────────

    def _build_vpn_view(self):
        view = self._box(Gtk.Orientation.VERTICAL, spacing=12, css="panel-stack")
        meta = self._label("", "panel-meta", xalign=1)
        view.append(self._detail_header("VPN", right_widget=meta))

        # Tailscale section
        ts_section = self._box(
            Gtk.Orientation.VERTICAL, spacing=10, css="vpn-section",
        )
        head = self._box(
            Gtk.Orientation.HORIZONTAL, spacing=12, css="vpn-head",
        )
        ic = self._label(G["shield"], "vpn-icon")
        ic.set_width_chars(3)
        head.append(ic)
        copy = self._box(Gtk.Orientation.VERTICAL, spacing=2)
        copy.set_hexpand(True)
        copy.append(self._label("Tailscale", "vpn-name"))
        ts_sub = self._label("", "vpn-sub")
        copy.append(ts_sub)
        head.append(copy)
        ts_sw = self._switch()
        head.append(ts_sw)
        ts_section.append(head)

        def _on_ts_toggle(_b):
            target = not self.effective(
                "tailscale.enabled", self.state["tailscale"]["enabled"],
            )
            self._pending_set("tailscale.enabled", target, ttl_s=10)
            self._set_class(ts_sw, "on", target)
            self._set_class(ts_section, "off", not target)
            if target:
                act_tailscale_up()
            else:
                act_tailscale_down()
        ts_sw.connect("clicked", _on_ts_toggle)

        ts_strip = Gtk.Grid(column_homogeneous=True, column_spacing=6)
        ts_strip.add_css_class("vpn-stat")
        ts_section.append(ts_strip)
        ts_exit_btn = Gtk.Button()
        ts_exit_btn.add_css_class("drawer-select")
        exit_inner = self._box(Gtk.Orientation.HORIZONTAL, spacing=6)
        ts_exit_name = self._label("None")
        exit_inner.append(ts_exit_name)
        exit_inner.append(self._label(G["chevron_right"]))
        ts_exit_btn.set_child(exit_inner)

        ts_exit_popover = Gtk.Popover()
        ts_exit_popover.set_parent(ts_exit_btn)
        ts_exit_popover.set_position(Gtk.PositionType.BOTTOM)
        ts_exit_box = self._box(
            Gtk.Orientation.VERTICAL, spacing=2, css="drawer-list",
        )
        ts_exit_popover.set_child(ts_exit_box)

        def _on_exit_btn_click(_b):
            self._clear(ts_exit_box)
            none_btn = self._drawer_item(
                G["globe"], "None", "Direct, no exit node", "›",
                subtle=False,
            )

            def _pick_none(_b):
                self._pending_set("tailscale.exit_node", "None", ttl_s=8)
                ts_exit_name.set_label("None")
                act_tailscale_exit_node("")
                ts_exit_popover.popdown()
            none_btn.connect("clicked", _pick_none)
            ts_exit_box.append(none_btn)
            for p in self.state["tailscale"]["peers"]:
                if p["this"] or not p["online"]:
                    continue
                row = self._drawer_item(
                    G["server"], self._short(p["name"], 22),
                    p["ip"] or "—", "›",
                )

                def _pick(_b, name=p["name"]):
                    self._pending_set("tailscale.exit_node", name, ttl_s=10)
                    ts_exit_name.set_label(name)
                    act_tailscale_exit_node(name)
                    ts_exit_popover.popdown()
                row.connect("clicked", _pick)
                ts_exit_box.append(row)
            ts_exit_popover.popup()
        ts_exit_btn.connect("clicked", _on_exit_btn_click)

        ts_section.append(self._drawer_row(
            G["globe"], "Exit Node",
            "Route all traffic through a tailnet peer",
            ts_exit_btn,
        ))
        ts_peer_section = self._section_label("Tailnet")
        ts_section.append(ts_peer_section)
        ts_peer_count_lbl = ts_peer_section.get_first_child()
        ts_list = self._box(
            Gtk.Orientation.VERTICAL, spacing=2, css="drawer-list",
        )
        ts_section.append(ts_list)
        view.append(ts_section)

        # Mullvad section
        mv_section = self._box(
            Gtk.Orientation.VERTICAL, spacing=10,
            css=["vpn-section", "off"],
        )
        head = self._box(
            Gtk.Orientation.HORIZONTAL, spacing=12, css="vpn-head",
        )
        ic = self._label(G["key"], "vpn-icon")
        ic.set_width_chars(3)
        head.append(ic)
        copy = self._box(Gtk.Orientation.VERTICAL, spacing=2)
        copy.set_hexpand(True)
        copy.append(self._label("Mullvad", "vpn-name"))
        mv_sub = self._label("", "vpn-sub")
        copy.append(mv_sub)
        head.append(copy)
        mv_sw = self._switch()
        head.append(mv_sw)
        mv_section.append(head)

        def _on_mv_toggle(_b):
            target = not self.effective(
                "mullvad.connected", self.state["mullvad"]["connected"],
            )
            self._pending_set("mullvad.connected", target, ttl_s=10)
            self._set_class(mv_sw, "on", target)
            self._set_class(mv_section, "off", not target)
            if target:
                act_mullvad_connect()
            else:
                act_mullvad_disconnect()
        mv_sw.connect("clicked", _on_mv_toggle)

        # Inline build of the location row so we can update its labels.
        mv_loc_row = self._box(
            Gtk.Orientation.HORIZONTAL, spacing=10, css="drawer-row",
        )
        mv_loc_icon = self._label("—", "di-icon")
        mv_loc_icon.set_width_chars(2)
        mv_loc_row.append(mv_loc_icon)
        loc_copy = self._box(Gtk.Orientation.VERTICAL, spacing=2)
        loc_copy.set_hexpand(True)
        mv_loc_name = self._label("—", "di-name")
        mv_loc_sub = self._label("", "di-sub")
        loc_copy.append(mv_loc_name)
        loc_copy.append(mv_loc_sub)
        mv_loc_row.append(loc_copy)
        mv_change_btn = self._drawer_select("Change")
        mv_loc_row.append(mv_change_btn)
        mv_section.append(mv_loc_row)

        # Mullvad location picker — curated short list. Full server list
        # via `mullvad relay list` is huge (1000+ rows); these covers most
        # daily use.
        mv_locs = [
            ("SE", "Sweden", "Stockholm", "se sto"),
            ("DE", "Germany", "Frankfurt", "de fra"),
            ("CH", "Switzerland", "Zürich", "ch zrh"),
            ("NL", "Netherlands", "Amsterdam", "nl ams"),
            ("GB", "United Kingdom", "London", "gb lon"),
            ("US", "USA", "New York", "us nyc"),
            ("JP", "Japan", "Tokyo", "jp tyo"),
        ]
        mv_popover = Gtk.Popover()
        mv_popover.set_parent(mv_change_btn)
        mv_popover.set_position(Gtk.PositionType.BOTTOM)
        mv_picker_box = self._box(
            Gtk.Orientation.VERTICAL, spacing=2, css="drawer-list",
        )
        for code, country, city, loc in mv_locs:
            r = self._drawer_item(
                code, self._short(country, 22), city, "›",
            )

            def _pick_loc(_b, lc=loc, lbl=f"{country}, {city}"):
                self._pending_set("mullvad.preferred", lbl, ttl_s=8)
                act_mullvad_set_location(lc)
                mv_popover.popdown()
            r.connect("clicked", _pick_loc)
            mv_picker_box.append(r)
        mv_popover.set_child(mv_picker_box)
        mv_change_btn.connect("clicked", lambda _b: mv_popover.popup())

        view.append(mv_section)
        view.append(self._ghost_btn("Open VPN Settings"))

        def refresh(s):
            ts = s["tailscale"]; mv = s["mullvad"]
            ts_enabled = self.effective("tailscale.enabled", ts["enabled"])
            mv_connected = self.effective("mullvad.connected", mv["connected"])
            active = (1 if ts_enabled else 0) + (1 if mv_connected else 0)
            meta.set_label(f"{active} of 2 active")

            self._set_class(ts_sw, "on", ts_enabled)
            self._set_class(ts_section, "off", not ts_enabled)

            name = ts["name"] or "—"
            ip = ts["ip"] or "—"
            ts_sub.set_label(self._short(
                f"{name} · {ip} · WireGuard mesh"
                if ts_enabled else "Not connected", 56,
            ))

            peer_count = ts["peer_count"]
            online = sum(1 for p in ts["peers"] if p.get("online"))
            self._fill_stat_grid(ts_strip, [
                (str(peer_count), "peers"),
                (str(online), "online"),
                (ts["os"] or "—", "os"),
            ])
            ts_exit_name.set_label(self.effective(
                "tailscale.exit_node", ts["exit_node"] or "None",
            ))

            ts_peer_count_lbl.set_label(
                f"Tailnet · {peer_count} peer{'s' if peer_count != 1 else ''}"
            )
            self._clear(ts_list)
            if not ts["peers"]:
                ts_list.append(self._drawer_item(
                    G["server"], "No peers",
                    "Tailscale not running or empty tailnet", "—",
                    subtle=True,
                ))
            else:
                for p in ts["peers"]:
                    if p["os"] == "linux" and "server" in (p["name"] or ""):
                        glyph = G["server"]
                    elif p["os"] in ("android", "iOS", "ios"):
                        glyph = G["phone"]
                    elif p["os"] == "linux":
                        glyph = G["laptop"]
                    else:
                        glyph = G["laptop"]
                    if p["this"]:
                        right = "This"; status = "this"
                    elif p["online"]:
                        right = "Online"; status = "online"
                    else:
                        right = "Offline"; status = None
                    sub = (f"{p['ip']} · this device"
                           if p["this"] else (p["ip"] or "—"))
                    ts_list.append(self._drawer_item(
                        glyph, self._short(p["name"] or "?", 22),
                        sub, right, active=p["online"], status=status,
                    ))

            self._set_class(mv_sw, "on", mv_connected)
            self._set_class(mv_section, "off", not mv_connected)
            if mv_connected:
                mv_sub.set_label(self._short(
                    f"{mv['location']} · WireGuard", 56,
                ))
            else:
                mv_sub.set_label("Not connected · WireGuard")

            preferred_disp = self.effective(
                "mullvad.preferred",
                f"{mv['country']}, {mv['city']}"
                if mv["country"] and mv["city"] else mv["preferred"],
            )
            country = mv["country"] or "—"
            mv_loc_icon.set_label(self._country_code(country))
            mv_loc_name.set_label(self._short(country, 28))
            mv_loc_sub.set_label(self._short(
                f"{mv['city']} · preferred {preferred_disp}"
                if preferred_disp else mv["city"] or "—",
                56,
            ))

        self._refreshers.append(refresh)
        refresh(self.state)
        return view

    # ── View: Do Not Disturb ──────────────────────────────────

    def _build_dnd_view(self):
        view = self._box(Gtk.Orientation.VERTICAL, spacing=12, css="panel-stack")
        sw = self._switch()
        view.append(self._detail_header("Do Not Disturb", right_widget=sw))

        def _on_dnd_toggle(_b):
            target_enabled = not self.effective(
                "dnd.enabled", self.state["dnd"]["enabled"],
            )
            self._pending_set("dnd.enabled", target_enabled, ttl_s=3)
            self._set_class(sw, "on", target_enabled)
            act_set_dnd_mode("do-not-disturb" if target_enabled else "default")
        sw.connect("clicked", _on_dnd_toggle)

        wrap = self._box(Gtk.Orientation.VERTICAL, spacing=8, css="surface")
        wrap.append(self._label("Silence notifications until…", "dnd-prompt"))
        seg = self._segmented([
            (G["clock"], "1 hour"),
            (G["sun"], "8 am"),
            (G["bell_off"], "Always"),
        ], click_visual=True)
        wrap.append(seg.widget)
        view.append(wrap)

        # The three preset buttons all enable DND; mako has no native
        # time-bound mode, so the timed presets schedule a GLib timeout
        # that fires `mode -s default` after the duration.
        def _enable_for(seconds, label=None):
            self._pending_set("dnd.enabled", True, ttl_s=3)
            self._set_class(sw, "on", True)
            act_set_dnd_mode("do-not-disturb")
            if seconds and seconds > 0:
                def _revert():
                    self._pending_set("dnd.enabled", False, ttl_s=3)
                    self._set_class(sw, "on", False)
                    act_set_dnd_mode("default")
                    return False
                GLib.timeout_add_seconds(int(seconds), _revert)

        def _seconds_until_8am():
            now = time.localtime()
            now_s = now.tm_hour * 3600 + now.tm_min * 60 + now.tm_sec
            target = 8 * 3600
            if now_s < target:
                return target - now_s
            return (24 * 3600 - now_s) + target

        seg.buttons[0].connect("clicked", lambda _b: _enable_for(3600))
        seg.buttons[1].connect("clicked", lambda _b: _enable_for(_seconds_until_8am()))
        seg.buttons[2].connect("clicked", lambda _b: _enable_for(0))

        view.append(self._ghost_btn("Open Notification Settings"))

        def refresh(s):
            self._set_class(sw, "on", self.effective(
                "dnd.enabled", s["dnd"]["enabled"],
            ))

        self._refreshers.append(refresh)
        refresh(self.state)
        return view

    # ── View: Volume ──────────────────────────────────────────

    def _build_volume_view(self):
        view = self._box(Gtk.Orientation.VERTICAL, spacing=12, css="panel-stack")
        mute_btn = self._icon_btn(G["volume"])
        mute_btn.connect("clicked", lambda _b: act_toggle_sink_mute())
        view.append(self._detail_header("Volume", right_widget=mute_btn))
        hero = self._hero_card_ref()
        view.append(hero.widget)
        main = self._box(Gtk.Orientation.VERTICAL, spacing=12,
                         css=["surface", "slider-block"])
        slider = self._slider_row(G["volume"])
        main.append(slider.widget)
        view.append(main)
        self._bind_slider(slider, act_set_sink_volume)
        slider.glyph_btn.connect("clicked", lambda _b: act_toggle_sink_mute())

        view.append(self._section_label("Output Devices", action="Detect"))
        out = self._box(Gtk.Orientation.VERTICAL, spacing=2, css="drawer-list")
        view.append(out)
        view.append(self._ghost_btn("Open Sound Settings"))

        def refresh(s):
            a = s["audio"]
            mute_btn.set_label(G["volume_mute"] if a["sink_muted"]
                               else G["volume"])

            hero.icon.set_label(self._sink_icon_glyph(a["sink_name"]))
            hero.title.set_label(self._short(a["sink_name"], 28))
            hero.sub.set_label("default sink")
            hero.big.set_label(str(a["sink_volume_pct"]))
            hero.small.set_label("muted" if a["sink_muted"] else "level")

            self._set_slider_polled(slider, a["sink_volume_pct"])
            slider.glyph_btn.set_label(
                G["volume_mute"] if a["sink_muted"] else G["volume"]
            )

            self._clear(out)
            if not a["sinks"]:
                out.append(self._drawer_item(
                    G["volume"], "No output devices", "—", "—",
                    subtle=True,
                ))
            else:
                for sink in a["sinks"]:
                    row = self._drawer_item(
                        self._sink_icon_glyph(sink["desc"]),
                        self._short(sink["desc"], 28),
                        f"id {sink['id']}",
                        "Active" if sink["default"] else "Switch",
                        active=sink["default"],
                    )
                    if not sink["default"]:
                        def _switch(_b, sid=sink["id"]):
                            act_set_default_sink(sid)
                        row.connect("clicked", _switch)
                    out.append(row)

        self._refreshers.append(refresh)
        refresh(self.state)
        return view

    # ── View: Microphone ──────────────────────────────────────

    def _build_microphone_view(self):
        view = self._box(Gtk.Orientation.VERTICAL, spacing=12, css="panel-stack")
        mute_btn = self._icon_btn(G["mic"])
        mute_btn.connect("clicked", lambda _b: act_toggle_source_mute())
        view.append(self._detail_header("Microphone", right_widget=mute_btn))
        hero = self._hero_card_ref()
        view.append(hero.widget)
        main = self._box(Gtk.Orientation.VERTICAL, spacing=12,
                         css=["surface", "slider-block"])
        slider = self._slider_row(G["mic"])
        main.append(slider.widget)
        view.append(main)
        self._bind_slider(slider, act_set_source_volume)
        slider.glyph_btn.connect("clicked", lambda _b: act_toggle_source_mute())

        view.append(self._section_label("Input Level", action="Test"))
        meter = self._box(Gtk.Orientation.HORIZONTAL, spacing=3, css="level-meter")
        # Static visual decor: real-time peak metering requires PipeWire stream
        # subscription, out of scope for the read-only data pass.
        levels = [22, 38, 58, 72, 48, 32, 56, 44, 28, 36, 22, 16]
        active = [True] * 8 + [False] * 4
        for h, on in zip(levels, active):
            bar = Gtk.Box()
            bar.add_css_class("meter-bar")
            if on:
                bar.add_css_class("active")
            bar.set_size_request(-1, int(h * 0.42))
            bar.set_valign(Gtk.Align.END)
            bar.set_hexpand(True)
            meter.append(bar)
        view.append(meter)

        view.append(self._section_label("Input Devices", action="Detect"))
        inp = self._box(Gtk.Orientation.VERTICAL, spacing=2, css="drawer-list")
        view.append(inp)

        view.append(self._ghost_btn("Open Sound Settings"))

        def refresh(s):
            a = s["audio"]
            mute_btn.set_label(G["mic_off"] if a["source_muted"] else G["mic"])

            hero.icon.set_label(G["mic_off"] if a["source_muted"] else G["mic"])
            hero.title.set_label(self._short(a["source_name"], 28))
            hero.sub.set_label("default source")
            hero.big.set_label(str(a["source_volume_pct"]))
            hero.small.set_label("muted" if a["source_muted"] else "level")

            self._set_slider_polled(slider, a["source_volume_pct"])
            slider.glyph_btn.set_label(
                G["mic_off"] if a["source_muted"] else G["mic"]
            )

            self._clear(inp)
            if not a["sources"]:
                inp.append(self._drawer_item(
                    G["mic"], "No input devices", "—", "—", subtle=True,
                ))
            else:
                for src in a["sources"]:
                    row = self._drawer_item(
                        G["mic"],
                        self._short(src["desc"], 28),
                        f"id {src['id']}",
                        "Active" if src["default"] else "Switch",
                        active=src["default"],
                    )
                    if not src["default"]:
                        def _switch(_b, sid=src["id"]):
                            act_set_default_source(sid)
                        row.connect("clicked", _switch)
                    inp.append(row)

        self._refreshers.append(refresh)
        refresh(self.state)
        return view

    # ── CSS ───────────────────────────────────────────────────

    def _css(self):
        bg = h2rgb(self.colors.get("bg", DEFAULTS["bg"]))
        brown = h2rgb(self.colors.get("brown", DEFAULTS["brown"]))
        orange = h2rgb(self.colors.get("orange", DEFAULTS["orange"]))
        amber = h2rgb(self.colors.get("amber", DEFAULTS["amber"]))
        text = h2rgb(self.colors.get("text", DEFAULTS["text"]))

        def rgba(rgb, a):
            return f"rgba({rgb[0]}, {rgb[1]}, {rgb[2]}, {a})"

        return f"""
        * {{
            font-family: "Inter", "JetBrainsMono Nerd Font", sans-serif;
            font-size: 12px;
            color: {rgba(text, 0.92)};
        }}
        window {{ background: transparent; }}

        #panel {{
            min-width: 400px;
            padding: 16px;
            border-radius: 20px;
            border: 1px solid {rgba(orange, 0.28)};
            background: linear-gradient(180deg,
                {rgba(bg, 0.96)} 0%,
                {rgba(brown, 0.92)} 100%);
            box-shadow:
                0 24px 56px rgba(0, 0, 0, 0.35),
                inset 0 1px 0 rgba(255, 255, 255, 0.03);
        }}

        .panel-stack {{ margin: 0; }}

        .panel-header {{ margin-bottom: 4px; }}
        .panel-title {{ font-size: 13px; font-weight: 600; letter-spacing: 0.03em; }}
        .panel-title.with-back {{ font-size: 14px; }}
        .panel-meta {{ color: {rgba(text, 0.42)}; font-size: 10px;
                       letter-spacing: 0.08em; }}

        .live-dot {{
            min-width: 7px; min-height: 7px;
            border-radius: 999px;
            color: {rgba(amber, 1.0)};
            font-size: 9px;
        }}

        .back-btn {{
            min-width: 28px; min-height: 28px;
            padding: 0 6px;
            border-radius: 8px;
            border: 1px solid {rgba(orange, 0.18)};
            background: rgba(255, 255, 255, 0.04);
            color: {rgba(text, 0.8)};
            box-shadow: none;
        }}
        .back-btn:hover {{
            background: rgba(255, 255, 255, 0.08);
            color: {rgba(text, 1.0)};
        }}

        /* Tile grid */
        .tile {{
            padding: 12px;
            border-radius: 13px;
            border: 1px solid {rgba(orange, 0.18)};
            background: rgba(255, 255, 255, 0.02);
            color: {rgba(text, 0.88)};
            box-shadow: none;
        }}
        .tile:hover {{ background: rgba(255, 255, 255, 0.05); }}
        .tile.on {{
            border-color: {rgba(amber, 0.45)};
            background: {rgba(amber, 0.10)};
        }}
        .tile-icon {{ margin-bottom: 4px; }}
        .tile-glyph {{
            min-width: 30px; min-height: 30px;
            padding: 4px 6px;
            border-radius: 9px;
            background: rgba(255, 255, 255, 0.05);
            color: {rgba(text, 0.78)};
            font-size: 14px;
        }}
        .tile.on .tile-glyph {{
            background: {rgba(amber, 0.22)};
            color: {rgba(amber, 1.0)};
        }}
        .tile-chevron {{ color: {rgba(text, 0.34)}; font-size: 11px; }}
        .tile.on .tile-chevron {{ color: {rgba(amber, 0.85)}; }}
        .tile-title {{ font-size: 12.5px; font-weight: 600; }}
        .tile-sub {{ color: {rgba(text, 0.46)}; font-size: 10.5px; }}
        .tile.on .tile-sub {{ color: {rgba(amber, 0.86)}; }}
        .tile-badge {{
            padding: 2px 6px;
            border-radius: 999px;
            background: {rgba(amber, 0.15)};
            color: {rgba(amber, 1.0)};
            font-size: 9px;
            font-weight: 600;
            letter-spacing: 0.06em;
        }}

        /* Generic surface + sections */
        .surface {{
            padding: 12px;
            border-radius: 14px;
            border: 1px solid {rgba(orange, 0.18)};
            background: rgba(255, 255, 255, 0.03);
        }}
        .section-label {{ margin-bottom: 4px; margin-top: 4px; }}
        .section-text, .section-label label {{
            color: {rgba(text, 0.42)};
            font-size: 10px;
            font-weight: 500;
            letter-spacing: 0.08em;
        }}
        .section-action {{
            padding: 2px 6px;
            background: transparent;
            border: none;
            color: {rgba(text, 0.62)};
            font-size: 10px;
            box-shadow: none;
        }}
        .section-action:hover {{ color: {rgba(text, 1.0)}; }}

        /* Sliders */
        .slider-row {{ margin: 0; }}
        .glyph-btn {{
            min-width: 26px; min-height: 26px;
            padding: 0 6px;
            border-radius: 8px;
            border: none;
            background: rgba(255, 255, 255, 0.04);
            color: {rgba(text, 0.78)};
            box-shadow: none;
        }}
        .glyph-btn:hover {{
            background: rgba(255, 255, 255, 0.08);
            color: {rgba(text, 1.0)};
        }}
        .slider-track {{
            min-height: 6px;
            margin: 10px 0;
            border-radius: 999px;
            background: rgba(255, 255, 255, 0.08);
        }}
        .slider-fill {{
            min-height: 6px;
            border-radius: 999px;
            background: linear-gradient(90deg,
                {rgba(amber, 0.55)}, {rgba(text, 0.92)});
        }}
        .slider-knob {{
            min-width: 12px; min-height: 12px;
            margin-left: auto;
            margin-top: -3px;
            border-radius: 999px;
            background: {rgba(text, 1.0)};
        }}
        .slider-value {{
            color: {rgba(text, 0.66)};
            font-size: 11px;
        }}
        .slider-aux {{
            padding: 4px 6px;
            background: transparent;
            border: none;
            color: {rgba(text, 0.5)};
            font-size: 10px;
            box-shadow: none;
        }}
        .slider-aux:hover {{ color: {rgba(text, 1.0)}; }}
        .app-slider {{ margin: 6px 0 0 0; min-height: 4px; }}
        .app-slider .slider-fill {{ min-height: 4px; }}

        /* Segmented */
        .segmented {{
            padding: 4px;
            border-radius: 12px;
            border: 1px solid {rgba(orange, 0.18)};
            background: rgba(255, 255, 255, 0.04);
        }}
        .seg {{
            padding: 6px 8px;
            border-radius: 9px;
            border: none;
            background: transparent;
            color: {rgba(text, 0.62)};
            font-size: 11px;
            box-shadow: none;
        }}
        .seg:hover {{ color: {rgba(text, 1.0)}; }}
        .seg.active {{
            color: {rgba(amber, 1.0)};
            background: {rgba(amber, 0.14)};
            box-shadow: inset 0 0 0 1px {rgba(amber, 0.32)};
        }}

        /* Chips */
        .chip-row {{ margin: 0; }}
        .chip {{
            padding: 7px 11px;
            border-radius: 10px;
            border: 1px solid {rgba(orange, 0.18)};
            background: rgba(255, 255, 255, 0.02);
            color: {rgba(text, 0.74)};
            font-size: 11px;
            box-shadow: none;
        }}
        .chip:hover {{
            background: rgba(255, 255, 255, 0.05);
            color: {rgba(text, 1.0)};
        }}
        .chip.on {{
            border-color: {rgba(amber, 0.45)};
            background: {rgba(amber, 0.12)};
            color: {rgba(amber, 1.0)};
        }}
        .chip-glyph {{ font-size: 12px; }}

        /* Theme picker */
        .theme-picker {{
            padding: 8px 0 4px;
        }}
        .theme-card {{
            padding: 6px;
            border-radius: 10px;
            border: 1px solid {rgba(orange, 0.18)};
            background: rgba(255, 255, 255, 0.025);
            box-shadow: none;
        }}
        .theme-card:hover {{ background: rgba(255, 255, 255, 0.05); }}
        .theme-card.active-theme {{
            border-color: {rgba(amber, 0.55)};
            background: {rgba(amber, 0.10)};
        }}
        .theme-card-name {{
            font-size: 10px;
            color: {rgba(text, 0.72)};
        }}
        .theme-card.active-theme .theme-card-name {{
            color: {rgba(amber, 1.0)};
        }}
        .theme-swatch {{
            min-height: 22px;
            border-radius: 6px;
            border: 1px solid rgba(255, 255, 255, 0.05);
        }}
        .theme-swatch.swatch-mono-mesh {{
            background: linear-gradient(90deg, #2a2a2a 0%, #888888 50%, #cccccc 100%);
        }}
        .theme-swatch.swatch-desert-dusk {{
            background: linear-gradient(90deg, #4a3728 0%, #c46e1a 50%, #e8890c 100%);
        }}
        .theme-swatch.swatch-acid-statue {{
            background: linear-gradient(90deg, #2e3a4a 0%, #4a7a6a 50%, #a8e840 100%);
        }}
        .theme-swatch.swatch-nighthawks {{
            background: linear-gradient(90deg, #2a3040 0%, #4a5568 50%, #8aa4b8 100%);
        }}

        /* Now playing */
        .nowplaying {{
            padding: 10px 12px;
            border-radius: 13px;
            border: 1px solid {rgba(orange, 0.16)};
            background: rgba(255, 255, 255, 0.025);
        }}
        .album-art {{
            min-width: 42px; min-height: 42px;
            border-radius: 9px;
            background: linear-gradient(135deg,
                {rgba(amber, 0.55)} 0%,
                {rgba(orange, 0.7)} 100%);
        }}
        .np-title {{ font-weight: 600; }}
        .np-artist {{ color: {rgba(text, 0.54)}; font-size: 10.5px; }}

        /* Stat grid + action row + icon buttons */
        .stat-cell {{
            padding: 10px 4px;
            border-radius: 12px;
            background: rgba(255, 255, 255, 0.025);
            border: 1px solid {rgba(orange, 0.16)};
        }}
        .stat-value {{ font-size: 15px; font-weight: 600; }}
        .stat-cell.accent .stat-value {{ color: {rgba(amber, 1.0)}; }}
        .stat-label {{
            color: {rgba(text, 0.46)};
            font-size: 9px;
            letter-spacing: 0.08em;
        }}

        .action-row {{}}
        .icon-btn {{
            min-height: 38px;
            padding: 0 8px;
            border-radius: 9px;
            border: 1px solid {rgba(orange, 0.18)};
            background: rgba(255, 255, 255, 0.04);
            color: {rgba(text, 0.74)};
            box-shadow: none;
            font-size: 14px;
        }}
        .icon-btn:hover {{
            background: rgba(255, 255, 255, 0.08);
            color: {rgba(text, 1.0)};
        }}
        .icon-btn.danger:hover {{
            color: rgb(232, 137, 32);
            border-color: rgba(232, 137, 32, 0.4);
        }}
        .icon-btn.primary {{
            background: {rgba(amber, 0.18)};
            color: {rgba(amber, 1.0)};
            border-color: {rgba(amber, 0.4)};
        }}

        /* Switch */
        .switch {{
            min-width: 38px; min-height: 22px;
            padding: 2px;
            border-radius: 999px;
            border: 1px solid {rgba(orange, 0.28)};
            background: rgba(255, 255, 255, 0.06);
            box-shadow: none;
        }}
        .switch.on {{
            background: {rgba(amber, 0.28)};
            border-color: {rgba(amber, 0.5)};
        }}
        .switch-knob {{
            min-width: 16px; min-height: 16px;
            border-radius: 999px;
            background: {rgba(text, 0.92)};
        }}
        .switch.on .switch-knob {{
            margin-left: 16px;
            background: {rgba(amber, 1.0)};
        }}

        /* Drawer list + items */
        .drawer-list {{
            padding: 6px;
            border-radius: 13px;
            border: 1px solid {rgba(orange, 0.18)};
            background: rgba(255, 255, 255, 0.03);
        }}
        .drawer-item {{
            padding: 8px;
            border-radius: 9px;
            border: none;
            background: transparent;
            box-shadow: none;
        }}
        .drawer-item:hover {{ background: rgba(255, 255, 255, 0.04); }}
        .drawer-item.active {{ background: {rgba(amber, 0.10)}; }}
        .drawer-item.subtle .di-name {{ color: {rgba(text, 0.6)}; }}
        .di-icon {{
            color: {rgba(text, 0.78)};
            font-size: 13px;
        }}
        .drawer-item.active .di-icon {{ color: {rgba(amber, 1.0)}; }}
        .di-name {{ font-weight: 500; }}
        .di-sub {{ color: {rgba(text, 0.5)}; font-size: 10px; }}
        .di-right {{
            color: {rgba(text, 0.5)};
            font-size: 10px;
            font-weight: 500;
            letter-spacing: 0.06em;
        }}
        .drawer-item.active .di-right {{ color: {rgba(amber, 1.0)}; }}

        .status-dot {{
            min-width: 6px; min-height: 6px;
            border-radius: 999px;
            background: {rgba(text, 0.25)};
        }}
        .status-dot.online {{ background: rgb(120, 200, 120); }}
        .status-dot.this {{ background: {rgba(amber, 1.0)}; }}

        .drawer-row {{
            padding: 10px;
            border-radius: 13px;
            border: 1px solid {rgba(orange, 0.18)};
            background: rgba(255, 255, 255, 0.025);
        }}
        .drawer-select {{
            padding: 5px 9px;
            border-radius: 8px;
            border: none;
            background: rgba(255, 255, 255, 0.05);
            color: {rgba(text, 0.78)};
            font-size: 11px;
            box-shadow: none;
        }}
        .drawer-select:hover {{
            background: rgba(255, 255, 255, 0.08);
            color: {rgba(text, 1.0)};
        }}

        /* Hero card (detail views) */
        .hero-card {{
            padding: 14px;
            border-radius: 14px;
            border: 1px solid {rgba(amber, 0.32)};
            background: linear-gradient(135deg,
                {rgba(amber, 0.14)} 0%,
                {rgba(amber, 0.04)} 100%);
        }}
        .hero-icon-wrap {{
            min-width: 44px; min-height: 44px;
            padding: 8px;
            border-radius: 12px;
            background: {rgba(amber, 0.22)};
            color: {rgba(amber, 1.0)};
            font-size: 18px;
        }}
        .hero-title {{ font-weight: 600; font-size: 13px; }}
        .hero-sub {{ color: {rgba(text, 0.6)}; font-size: 10.5px; }}
        .hero-big {{
            font-size: 18px;
            font-weight: 600;
            color: {rgba(amber, 1.0)};
        }}
        .hero-small {{
            color: {rgba(text, 0.5)};
            font-size: 9px;
            letter-spacing: 0.08em;
        }}

        /* VPN sections */
        .vpn-section {{
            padding: 12px;
            border-radius: 14px;
            border: 1px solid {rgba(orange, 0.18)};
            background: rgba(255, 255, 255, 0.025);
        }}
        .vpn-section.off {{ opacity: 0.62; }}
        .vpn-icon {{
            min-width: 38px; min-height: 38px;
            padding: 8px;
            border-radius: 11px;
            background: {rgba(amber, 0.18)};
            color: {rgba(amber, 1.0)};
            font-size: 16px;
        }}
        .vpn-section.off .vpn-icon {{
            background: rgba(255, 255, 255, 0.05);
            color: {rgba(text, 0.5)};
        }}
        .vpn-name {{ font-weight: 600; font-size: 13px; }}
        .vpn-sub {{ color: {rgba(text, 0.55)}; font-size: 10.5px; }}
        .vpn-stat {{
            padding: 8px;
            border-radius: 10px;
            background: rgba(255, 255, 255, 0.025);
            border: 1px solid {rgba(orange, 0.14)};
        }}
        .vpn-stat-cell {{ padding: 4px 2px; }}
        .vpn-stat-value {{ font-size: 12px; font-weight: 600; }}
        .vpn-stat-label {{
            color: {rgba(text, 0.42)};
            font-size: 9px;
            letter-spacing: 0.08em;
        }}

        /* DND */
        .dnd-prompt {{
            color: {rgba(text, 0.6)};
            font-size: 11px;
            margin-bottom: 4px;
        }}

        /* Mic level meter */
        .level-meter {{
            padding: 12px;
            min-height: 64px;
            border-radius: 12px;
            border: 1px solid {rgba(orange, 0.16)};
            background: rgba(255, 255, 255, 0.025);
        }}
        .meter-bar {{
            min-width: 6px;
            background: {rgba(text, 0.16)};
            border-radius: 2px;
        }}
        .meter-bar.active {{
            background: linear-gradient(180deg,
                {rgba(amber, 1.0)} 0%,
                {rgba(amber, 0.55)} 100%);
        }}

        /* Ghost button (footer of detail views) */
        .ghost-btn {{
            padding: 9px 12px;
            border-radius: 11px;
            border: 1px solid {rgba(orange, 0.2)};
            background: rgba(255, 255, 255, 0.02);
            color: {rgba(text, 0.74)};
            font-size: 11px;
            box-shadow: none;
        }}
        .ghost-btn:hover {{
            background: rgba(255, 255, 255, 0.05);
            color: {rgba(text, 1.0)};
        }}
        """


# ── Entry point ──────────────────────────────────────────────────


def main():
    initial = "home"
    if len(sys.argv) == 2:
        arg = sys.argv[1]
        if arg in VIEWS:
            initial = arg
        elif arg in ("-h", "--help"):
            print(f"usage: control-center [{'|'.join(VIEWS)}]")
            return 0
        else:
            print(f"usage: control-center [{'|'.join(VIEWS)}]", file=sys.stderr)
            return 2
    elif len(sys.argv) > 2:
        print(f"usage: control-center [{'|'.join(VIEWS)}]", file=sys.stderr)
        return 2

    acquire_lock()
    state = read_state()
    pid = state.get("pid")
    current = state.get("view")
    if isinstance(pid, int) and process_alive(pid):
        os.kill(pid, signal.SIGTERM)
        if current == initial:
            clear_state(pid)
            release_lock()
            return 0
        for _ in range(20):
            if not process_alive(pid):
                break
            GLib.usleep(25_000)

    write_state(os.getpid(), initial)
    release_lock()
    initial_state = gather_state()
    app = ControlCenter(initial, load_colors(), initial_state)
    return app.run(None)


if __name__ == "__main__":
    raise SystemExit(main())
