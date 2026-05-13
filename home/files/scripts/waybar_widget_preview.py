#!/usr/bin/env python3
"""Static widget preview popups for Waybar mock interactions."""

import ctypes
import fcntl
import json
import os
import re
import shutil
import signal
import subprocess
import sys

os.environ["GDK_BACKEND"] = "wayland"

_gls = os.environ.get("GTK4_LAYER_SHELL_LIB", "")
if _gls:
    ctypes.CDLL(_gls, mode=ctypes.RTLD_GLOBAL)

import gi

gi.require_version("Gtk4LayerShell", "1.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, GLib, Gtk, Gtk4LayerShell


STATE_PATH = "/tmp/waybar-widget-preview.json"
LOCK_PATH = "/tmp/waybar-widget-preview.lock"
_lock_fd = None

DEFAULTS = {
    "bg": "161a20",
    "brown": "1f252d",
    "orange": "4a5568",
    "amber": "8aa4b8",
    "text": "c8d0d8",
}

PANELS = {
    "wifi": {
        "title": "Wi-Fi",
        "meta": "Click Widget",
        "hero": ("󰤨", "Home Fiber 5G", "Connected · Strong signal · Secure"),
        "section": "Available Networks",
        "items": [
            ("󰤨", "Home Fiber 5G", "Connected automatically", "Active", "selected"),
            ("󰤥", "Studio Backup", "Saved network", "Connect", ""),
            ("󰤯", "Guest", "Open network", "Join", ""),
        ],
        "buttons": ("Rescan", "Network Settings"),
    },
    "bluetooth": {
        "title": "Bluetooth",
        "meta": "Click Widget",
        "hero": ("󰂱", "WH-1000XM5", "Connected for audio · 76% battery"),
        "section": "Paired Devices",
        "items": [
            ("󰋋", "WH-1000XM5", "Audio output", "Connected", "selected"),
            ("󰄜", "MX Master 3S", "Mouse", "Ready", ""),
            ("󰂲", "Add New Device", "Scan for nearby devices", "Open", "subtle"),
        ],
        "buttons": None,
    },
    "audio": {
        "title": "Volume",
        "meta": "Starter Design",
        "hero": ("󰕾", "Speakers", "Default output · Balanced"),
        "sliders": [
            ("󰕾", 72),
            ("󰍬", 38),
        ],
        "section": "Output Devices",
        "items": [
            ("󰓃", "Built-in Speakers", "Analog Stereo", "Active", "selected"),
            ("󰋋", "WH-1000XM5", "Bluetooth audio", "Switch", ""),
        ],
        "buttons": ("Mute", "Sound Settings"),
    },
}


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


def run(argv, timeout=3):
    if not argv or shutil.which(argv[0]) is None:
        return ""
    try:
        proc = subprocess.run(
            argv,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return proc.stdout.strip()


def spawn(argv):
    if not argv or shutil.which(argv[0]) is None:
        return
    try:
        subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


def clamp_percent(value):
    return max(0, min(100, int(round(value))))


def parse_wpctl_volume(target):
    output = run(["wpctl", "get-volume", target])
    match = re.search(r"Volume:\s+([0-9.]+)", output)
    value = clamp_percent(float(match.group(1)) * 100) if match else 0
    muted = "[MUTED]" in output
    return value, muted


def parse_wpctl_nodes(section_name):
    status = run(["wpctl", "status"])
    nodes = []
    in_section = False
    for line in status.splitlines():
        stripped = line.strip()
        if stripped.startswith("├─ ") or stripped.startswith("└─ "):
            in_section = stripped.endswith(f"{section_name}:")
            continue
        if not in_section:
            continue
        match = re.match(
            r"(?:[│\s]*)(\*)?\s*(\d+)\.\s+(.+?)\s*(?:\[vol:\s*([0-9.]+)\])?\s*$",
            line,
        )
        if match:
            default, node_id, name, volume = match.groups()
            nodes.append(
                {
                    "id": node_id,
                    "name": " ".join(name.split()),
                    "volume": clamp_percent(float(volume) * 100) if volume else None,
                    "default": bool(default),
                }
            )
    return nodes


def is_hidden_audio_sink(sink):
    name = sink["name"].lower()
    inactive_monitor = (
        "hdmi" in name
        or "displayport" in name
        or "display port" in name
        or "monitor" in name
    )
    return inactive_monitor and not sink["default"]


def wifi_icon(signal_strength):
    if signal_strength >= 75:
        return "󰤨"
    if signal_strength >= 50:
        return "󰤥"
    if signal_strength >= 25:
        return "󰤢"
    return "󰤯"


def unique_wifi_rows(rows):
    seen = set()
    unique = []
    for row in rows:
        ssid = row["ssid"]
        if not ssid or ssid in seen:
            continue
        seen.add(ssid)
        unique.append(row)
    return unique


def build_audio_panel():
    sink_volume, sink_muted = parse_wpctl_volume("@DEFAULT_AUDIO_SINK@")
    source_volume, source_muted = parse_wpctl_volume("@DEFAULT_AUDIO_SOURCE@")
    sinks = parse_wpctl_nodes("Sinks")
    default_sink = next((sink for sink in sinks if sink["default"]), None)
    visible_sinks = [sink for sink in sinks if not is_hidden_audio_sink(sink)]
    if default_sink and default_sink not in visible_sinks:
        visible_sinks.insert(0, default_sink)
    sink_name = default_sink["name"] if default_sink else "Default Output"
    subtitle = f"{sink_volume}% volume"
    if sink_muted:
        subtitle += " · Muted"

    items = []
    for sink in visible_sinks[:5]:
        selected = sink["default"]
        right = "Active" if selected else "Switch"
        volume = f"{sink['volume']}% volume" if sink["volume"] is not None else "Output device"
        items.append(
            (
                "󰓃" if "speaker" in sink["name"].lower() else "󰋋",
                sink["name"],
                volume,
                right,
                "selected" if selected else "",
                None if selected else ["wpctl", "set-default", sink["id"]],
            )
        )
    if not items:
        items.append(("󰕾", "No output devices", "PipeWire did not report sinks", "", "subtle", None))

    return {
        "title": "Volume",
        "meta": "Live",
        "hero": ("󰝟" if sink_muted else "󰕾", sink_name, subtitle),
        "hero_on": not sink_muted,
        "sliders": [
            ("󰕾", sink_volume),
            ("󰍬", source_volume if not source_muted else 0),
        ],
        "section": "Output Devices",
        "items": items,
        "buttons": [
            ("Unmute" if sink_muted else "Mute", ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]),
            ("Sound Settings", ["pavucontrol"]),
        ],
    }


def build_wifi_panel():
    radio = run(["nmcli", "-t", "-f", "WIFI", "radio"]) or "unknown"
    rows = []
    output = run(["nmcli", "-t", "-f", "ACTIVE,SSID,SIGNAL,SECURITY", "dev", "wifi", "list", "--rescan", "no"])
    for line in output.splitlines():
        parts = line.split(":")
        if len(parts) < 4:
            continue
        active, ssid, signal_text, security = parts[0], parts[1], parts[2], ":".join(parts[3:])
        try:
            signal_strength = int(signal_text or "0")
        except ValueError:
            signal_strength = 0
        rows.append(
            {
                "active": active == "yes",
                "ssid": ssid,
                "signal": signal_strength,
                "security": security or "Open",
            }
        )

    rows = unique_wifi_rows(rows)
    connected = next((row for row in rows if row["active"]), None)
    if connected:
        hero = (
            wifi_icon(connected["signal"]),
            connected["ssid"],
            f"Connected · {connected['signal']}% signal · {connected['security']}",
        )
    else:
        hero = ("󰤭", "Not Connected", "Wi-Fi radio " + radio)

    items = []
    for row in rows[:6]:
        selected = row["active"]
        right = "Active" if selected else "Connect"
        subtitle = f"{row['signal']}% signal · {row['security']}"
        items.append(
            (
                wifi_icon(row["signal"]),
                row["ssid"],
                subtitle,
                right,
                "selected" if selected else "",
                None if selected else ["nmcli", "device", "wifi", "connect", row["ssid"]],
            )
        )
    if not items:
        items.append(("󰤭", "No networks found", "Run a rescan or check NetworkManager", "", "subtle", None))

    return {
        "title": "Wi-Fi",
        "meta": "Live",
        "hero": hero,
        "hero_on": radio == "enabled",
        "section": "Available Networks",
        "items": items,
        "buttons": [
            ("Rescan", ["nmcli", "device", "wifi", "rescan"]),
            ("Network Settings", ["nm-connection-editor"]),
        ],
    }


def parse_bluetooth_devices(kind):
    devices = []
    for line in run(["bluetoothctl", "devices", kind]).splitlines():
        match = re.match(r"Device\s+([0-9A-F:]{17})\s+(.+)", line)
        if match:
            devices.append({"mac": match.group(1), "name": match.group(2)})
    return devices


def bluetooth_devices_from_audio():
    devices = []
    for sink in parse_wpctl_nodes("Sinks"):
        if "bluez" in sink["name"].lower() or "buds" in sink["name"].lower():
            devices.append({"mac": "", "name": sink["name"], "connected": sink["default"]})
    if devices:
        return devices

    status = run(["wpctl", "status"])
    for line in status.splitlines():
        if "[bluez5]" not in line:
            continue
        match = re.search(r"\d+\.\s+(.+?)\s+\[bluez5\]", line)
        if match:
            devices.append({"mac": "", "name": " ".join(match.group(1).split()), "connected": True})
    return devices


def build_bluetooth_panel():
    show = run(["bluetoothctl", "show"])
    paired = parse_bluetooth_devices("Paired")
    connected_devices = parse_bluetooth_devices("Connected")
    audio_devices = bluetooth_devices_from_audio()
    powered = "Powered: yes" in show or bool(connected_devices) or bool(audio_devices)
    connected = {device["mac"] for device in connected_devices}

    devices_by_key = {}
    for device in paired:
        devices_by_key[device["mac"] or device["name"]] = {**device, "connected": device["mac"] in connected}
    for device in connected_devices:
        devices_by_key[device["mac"] or device["name"]] = {**device, "connected": True}
    for device in audio_devices:
        devices_by_key[device["mac"] or device["name"]] = device

    devices = list(devices_by_key.values())
    active = next((device for device in devices if device.get("connected")), None)

    if active:
        hero = ("󰂱", active["name"], "Connected")
    else:
        hero = ("󰂯" if powered else "󰂲", "Bluetooth", "Powered on" if powered else "Powered off")

    items = []
    for device in devices[:6]:
        is_connected = device.get("connected", False)
        action = None
        if device.get("mac"):
            action = ["bluetoothctl", "disconnect" if is_connected else "connect", device["mac"]]
        items.append(
            (
                "󰋋" if is_connected else "󰂯",
                device["name"],
                device.get("mac") or "Connected through PipeWire",
                "Disconnect" if is_connected and action else "Connect" if action else "Active",
                "selected" if is_connected else "",
                action,
            )
        )
    if not items:
        items.append(("󰂲", "No paired devices", "Pair devices in Bluetooth Manager", "", "subtle", None))

    return {
        "title": "Bluetooth",
        "meta": "Live",
        "hero": hero,
        "hero_on": powered,
        "section": "Paired Devices",
        "items": items,
        "buttons": [
            ("Power Off" if powered else "Power On", ["bluetoothctl", "power", "off" if powered else "on"]),
            ("Bluetooth Manager", ["blueman-manager"]),
        ],
    }


def build_panel(panel_name):
    builders = {
        "audio": build_audio_panel,
        "wifi": build_wifi_panel,
        "bluetooth": build_bluetooth_panel,
    }
    try:
        return builders[panel_name]()
    except Exception:
        return PANELS[panel_name]


def read_state():
    try:
        with open(STATE_PATH) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def write_state(pid, panel):
    with open(STATE_PATH, "w") as f:
        json.dump({"pid": pid, "panel": panel}, f)


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


class WidgetPreview(Gtk.Application):
    def __init__(self, panel_name, colors):
        super().__init__(application_id=f"io.personal.waybar-preview.{panel_name}")
        self.panel_name = panel_name
        self.panel = build_panel(panel_name)
        self.colors = colors
        self.connect("activate", self._build)

    def _build(self, _app):
        provider = Gtk.CssProvider()
        provider.load_from_data(self._css().encode())
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

        win = Gtk.ApplicationWindow(application=self)
        win.set_decorated(False)
        win.set_resizable(False)
        win.connect("close-request", self._on_close_request)

        Gtk4LayerShell.init_for_window(win)
        Gtk4LayerShell.set_layer(win, Gtk4LayerShell.Layer.OVERLAY)
        Gtk4LayerShell.set_anchor(win, Gtk4LayerShell.Edge.TOP, True)
        Gtk4LayerShell.set_anchor(win, Gtk4LayerShell.Edge.RIGHT, True)
        Gtk4LayerShell.set_margin(win, Gtk4LayerShell.Edge.TOP, 60)
        Gtk4LayerShell.set_margin(win, Gtk4LayerShell.Edge.RIGHT, 15)
        Gtk4LayerShell.set_keyboard_mode(win, Gtk4LayerShell.KeyboardMode.ON_DEMAND)
        Gtk4LayerShell.set_namespace(win, "waybar-widget-preview")

        key = Gtk.EventControllerKey()
        key.connect("key-pressed", self._on_key)
        win.add_controller(key)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.set_name("panel")
        root.set_spacing(10)
        root.set_size_request(336, -1)
        root.append(self._header())
        root.append(self._hero())

        if self.panel_name == "audio":
            root.append(self._sliders())

        root.append(self._list_surface())

        if self.panel.get("buttons"):
            root.append(self._button_row())

        win.set_child(root)
        win.present()

    def _on_close_request(self, *_args):
        clear_state(os.getpid())
        return False

    def _on_key(self, _ctrl, keyval, _keycode, _state):
        if keyval == Gdk.KEY_Escape:
            self.quit()
            return True
        return False

    def _header(self):
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        row.add_css_class("panel-header")

        title = Gtk.Label(label=self.panel["title"], xalign=0)
        title.add_css_class("panel-title")
        meta = Gtk.Label(label=self.panel["meta"], xalign=1)
        meta.add_css_class("panel-meta")

        row.append(title)
        spacer = Gtk.Box(hexpand=True)
        row.append(spacer)
        row.append(meta)
        return row

    def _hero(self):
        icon, title_text, subtitle_text = self.panel["hero"]

        surface = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        surface.add_css_class("surface")
        surface.add_css_class("hero")
        surface.set_spacing(12)

        icon_box = Gtk.Label(label=icon)
        icon_box.add_css_class("hero-icon")

        copy = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        copy.add_css_class("hero-copy")
        copy.set_spacing(3)
        title = Gtk.Label(label=title_text, xalign=0)
        title.add_css_class("hero-title")
        subtitle = Gtk.Label(label=subtitle_text, xalign=0)
        subtitle.add_css_class("hero-subtitle")
        copy.append(title)
        copy.append(subtitle)

        toggle = self._toggle(self.panel.get("hero_on", True))

        surface.append(icon_box)
        copy.set_hexpand(True)
        surface.append(copy)
        surface.append(toggle)
        return surface

    def _toggle(self, active):
        toggle = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        toggle.add_css_class("toggle")
        if active:
            toggle.add_css_class("on")

        knob = Gtk.Box()
        knob.add_css_class("toggle-knob")
        toggle.append(knob)
        return toggle

    def _sliders(self):
        surface = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        surface.add_css_class("surface")
        surface.add_css_class("slider-block")
        surface.set_spacing(8)

        for icon, value in self.panel["sliders"]:
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
            row.add_css_class("slider-row")
            row.set_spacing(10)

            left = Gtk.Label(label=icon)
            left.add_css_class("slider-icon")

            track = Gtk.Box()
            track.add_css_class("slider-track")
            track.set_hexpand(True)

            fill = Gtk.Box()
            fill.add_css_class("slider-fill")
            fill.set_size_request(int(value * 2), -1)

            knob = Gtk.Box()
            knob.add_css_class("slider-knob")
            fill.append(knob)
            track.append(fill)

            right = Gtk.Label(label=str(value))
            right.add_css_class("slider-value")

            row.append(left)
            row.append(track)
            row.append(right)
            surface.append(row)

        return surface

    def _list_surface(self):
        surface = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        surface.add_css_class("surface")

        section = Gtk.Label(label=self.panel["section"], xalign=0)
        section.add_css_class("section-label")
        surface.append(section)

        lst = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        lst.add_css_class("list")
        lst.set_spacing(6)
        for row in self.panel["items"]:
            icon, title_text, subtitle_text, right_text, klass, *rest = row
            action = rest[0] if rest else None
            item = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
            item.add_css_class("item")
            item.set_spacing(10)
            if klass:
                item.add_css_class(klass)

            left = Gtk.Label(label=icon)
            left.add_css_class("item-left")

            copy = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            copy.add_css_class("item-copy")
            copy.set_spacing(2)
            title = Gtk.Label(label=title_text, xalign=0)
            title.add_css_class("item-title")
            subtitle = Gtk.Label(label=subtitle_text, xalign=0)
            subtitle.add_css_class("item-subtitle")
            copy.append(title)
            copy.append(subtitle)
            copy.set_hexpand(True)

            right = Gtk.Label(label=right_text, xalign=1)
            right.add_css_class("item-right")

            item.append(left)
            item.append(copy)
            item.append(right)
            if action:
                button = Gtk.Button()
                button.add_css_class("item-button")
                button.set_child(item)
                button.connect("clicked", self._on_action_clicked, action)
                lst.append(button)
            else:
                lst.append(item)

        surface.append(lst)
        return surface

    def _button_row(self):
        button_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        button_row.add_css_class("button-row")
        button_row.set_spacing(8)

        for index, button_spec in enumerate(self.panel["buttons"]):
            label, action = button_spec if isinstance(button_spec, tuple) else (button_spec, None)
            button = Gtk.Button(label=label)
            button.set_hexpand(True)
            button.add_css_class("panel-button")
            button.add_css_class("solid-btn" if index == 1 else "ghost-btn")
            if action:
                button.connect("clicked", self._on_action_clicked, action)
            else:
                button.set_sensitive(False)
            button_row.append(button)

        return button_row

    def _on_action_clicked(self, _button, action):
        spawn(action)
        clear_state(os.getpid())
        self.quit()

    def _css(self):
        bg = h2rgb(self.colors["bg"])
        brown = h2rgb(self.colors.get("brown", DEFAULTS["brown"]))
        orange = h2rgb(self.colors["orange"])
        amber = h2rgb(self.colors["amber"])
        text = h2rgb(self.colors["text"])

        return f"""
        * {{
            font-family: "Inter", "JetBrainsMono Nerd Font", sans-serif;
            font-size: 12px;
        }}

        window {{
            background: transparent;
        }}

        #panel {{
            min-width: 336px;
            padding: 14px;
            border-radius: 18px;
            border: 1px solid rgba({orange[0]}, {orange[1]}, {orange[2]}, 0.28);
            background: linear-gradient(
                180deg,
                rgba({bg[0]}, {bg[1]}, {bg[2]}, 0.94) 0%,
                rgba({brown[0]}, {brown[1]}, {brown[2]}, 0.88) 100%
            );
            box-shadow:
                0 20px 50px rgba(0, 0, 0, 0.3),
                inset 0 1px 0 rgba(255, 255, 255, 0.03);
        }}

        .panel-header {{
            margin-bottom: 2px;
        }}

        .panel-title {{
            color: rgba({text[0]}, {text[1]}, {text[2]}, 1.0);
            font-size: 13px;
            font-weight: 600;
            letter-spacing: 0.03em;
        }}

        .panel-meta {{
            color: rgba({text[0]}, {text[1]}, {text[2]}, 0.42);
            font-size: 10px;
            font-weight: 500;
            letter-spacing: 0.08em;
        }}

        .surface {{
            padding: 10px;
            border-radius: 14px;
            border: 1px solid rgba({orange[0]}, {orange[1]}, {orange[2]}, 0.18);
            background: rgba(255, 255, 255, 0.03);
        }}

        .hero {{
            margin: 0;
        }}

        .hero-icon {{
            min-width: 34px;
            min-height: 34px;
            padding: 8px 9px;
            border-radius: 11px;
            background: rgba({amber[0]}, {amber[1]}, {amber[2]}, 0.08);
            color: rgba({amber[0]}, {amber[1]}, {amber[2]}, 1.0);
            font-size: 16px;
        }}

        .hero-title {{
            color: rgba({text[0]}, {text[1]}, {text[2]}, 1.0);
            font-weight: 600;
        }}

        .hero-subtitle {{
            color: rgba({text[0]}, {text[1]}, {text[2]}, 0.55);
            font-size: 11px;
        }}

        .toggle {{
            min-width: 42px;
            min-height: 24px;
            padding: 2px;
            border-radius: 999px;
            border: 1px solid rgba({orange[0]}, {orange[1]}, {orange[2]}, 0.28);
            background: rgba(255, 255, 255, 0.06);
        }}

        .toggle.on {{
            background: rgba({amber[0]}, {amber[1]}, {amber[2]}, 0.24);
            border-color: rgba({amber[0]}, {amber[1]}, {amber[2]}, 0.4);
        }}

        .toggle-knob {{
            min-width: 18px;
            min-height: 18px;
            border-radius: 999px;
            background: rgba({text[0]}, {text[1]}, {text[2]}, 0.92);
        }}

        .toggle.on .toggle-knob {{
            margin-left: 18px;
            background: rgba({amber[0]}, {amber[1]}, {amber[2]}, 1.0);
        }}

        .slider-icon,
        .slider-value {{
            color: rgba({text[0]}, {text[1]}, {text[2]}, 0.86);
        }}

        .slider-track {{
            min-height: 6px;
            margin: 8px 0;
            border-radius: 999px;
            background: rgba(255, 255, 255, 0.08);
        }}

        .slider-fill {{
            min-height: 6px;
            border-radius: 999px;
            background: linear-gradient(
                90deg,
                rgba({amber[0]}, {amber[1]}, {amber[2]}, 0.72),
                rgba({text[0]}, {text[1]}, {text[2]}, 0.92)
            );
        }}

        .slider-knob {{
            min-width: 12px;
            min-height: 12px;
            margin-left: auto;
            margin-top: -3px;
            border-radius: 999px;
            background: rgba({text[0]}, {text[1]}, {text[2]}, 1.0);
        }}

        .section-label {{
            margin-bottom: 8px;
            color: rgba({text[0]}, {text[1]}, {text[2]}, 0.42);
            font-size: 10px;
            font-weight: 500;
            letter-spacing: 0.08em;
        }}

        .item {{
            padding: 10px 11px;
            border-radius: 12px;
            background: rgba(255, 255, 255, 0.02);
        }}

        .item-button {{
            padding: 0;
            border: 0;
            border-radius: 12px;
            background: transparent;
            box-shadow: none;
        }}

        .item-button:hover .item {{
            background: rgba(255, 255, 255, 0.05);
        }}

        .item.selected {{
            background: rgba({amber[0]}, {amber[1]}, {amber[2]}, 0.09);
        }}

        .item.subtle label {{
            color: rgba({text[0]}, {text[1]}, {text[2]}, 0.56);
        }}

        .item-left {{
            min-width: 24px;
            color: rgba({text[0]}, {text[1]}, {text[2]}, 0.78);
        }}

        .item-title {{
            color: rgba({text[0]}, {text[1]}, {text[2]}, 0.86);
        }}

        .item-subtitle {{
            color: rgba({text[0]}, {text[1]}, {text[2]}, 0.46);
            font-size: 10px;
        }}

        .item-right {{
            color: rgba({text[0]}, {text[1]}, {text[2]}, 0.4);
            font-size: 10px;
            font-weight: 500;
            letter-spacing: 0.08em;
        }}

        .panel-button {{
            min-width: 0;
            padding: 9px 12px;
            border-radius: 11px;
            border: 1px solid rgba({orange[0]}, {orange[1]}, {orange[2]}, 0.2);
            box-shadow: none;
        }}

        .panel-button:disabled {{
            opacity: 1;
        }}

        .ghost-btn {{
            color: rgba({text[0]}, {text[1]}, {text[2]}, 0.74);
            background: rgba(255, 255, 255, 0.02);
        }}

        .solid-btn {{
            color: rgba({bg[0]}, {bg[1]}, {bg[2]}, 1.0);
            background: rgba({amber[0]}, {amber[1]}, {amber[2]}, 1.0);
            border-color: rgba({amber[0]}, {amber[1]}, {amber[2]}, 0.55);
        }}
        """


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in PANELS:
        print("usage: waybar-widget-preview {wifi|bluetooth|audio}", file=sys.stderr)
        return 2

    panel = sys.argv[1]
    acquire_lock()

    state = read_state()
    pid = state.get("pid")
    current_panel = state.get("panel")
    if isinstance(pid, int) and process_alive(pid):
        os.kill(pid, signal.SIGTERM)
        if current_panel == panel:
            clear_state(pid)
            release_lock()
            return 0
        for _ in range(20):
            if not process_alive(pid):
                break
            GLib.usleep(25_000)

    write_state(os.getpid(), panel)
    release_lock()
    app = WidgetPreview(panel, load_colors())
    return app.run(None)


if __name__ == "__main__":
    raise SystemExit(main())
