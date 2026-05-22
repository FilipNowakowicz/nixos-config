"""Write-side actions: subprocess fire-and-forget plus a few stateful helpers.

Owns the module-level globals that are shared with the state-gathering pass:
``_inhibit_proc`` (also read by ``gather.gather_keep_awake``) and
``_art_cache`` / ``_art_pending`` (also read by the home view).
"""

import json
import os
import shutil
import subprocess
import tempfile
import threading
import urllib.request

from gi.repository import Gio, GLib

# Globals shared with the gather pass / views.
_inhibit_proc = None
_location_cache = None  # (lat, lon) once resolved
_location_lock = threading.Lock()
_art_cache = {}   # art_url -> local path (or None if failed)
_art_pending = set()  # art_urls currently being fetched


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


def _fire_if_found(cmd):
    try:
        exe = shutil.which(cmd[0])
    except Exception:
        exe = None
    if exe:
        _fire([exe, *cmd[1:]])
        return True
    return False


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


def act_wifi_rescan():
    _fire(["nmcli", "dev", "wifi", "rescan"])


def act_open_network_settings():
    _fire_if_found(["nm-connection-editor"])


def act_open_hidden_wifi():
    _fire_if_found(["nm-connection-editor", "--create", "--type=wifi"])


def act_bt_scan():
    _fire(["bluetoothctl", "scan", "on"])


def act_open_bluetooth_settings():
    _fire_if_found(["blueman-manager"])


def act_open_sound_settings():
    _fire_if_found(["pavucontrol"])


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


def act_open_vpn_tools():
    if _fire_if_found([
        "kitty", "-e", "sh", "-lc",
        "printf '\\nVPN tools\\n========\\n\\nMullvad status:\\n'; "
        "mullvad status 2>/dev/null || true; "
        "printf '\\nRelay:\\n'; mullvad relay get 2>/dev/null || true; "
        "printf '\\nTailscale status:\\n'; tailscale status 2>/dev/null || true; "
        "printf '\\nPress Ctrl-D to close.\\n'; exec ${SHELL:-sh} -i",
    ]):
        return
    _fire_if_found(["mullvad", "status"])


def act_open_notification_config():
    if _fire_if_found([
        "kitty", "-e", "nvim", os.path.expanduser("~/.config/mako/config"),
    ]):
        return
    _fire_if_found(["xdg-open", os.path.expanduser("~/.config/mako/config")])


def act_switch_theme(name):
    _fire(["theme-switch", name])


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
        r = subprocess.run(
            ["curl", "-sf", "--max-time", "3", "http://ip-api.com/json"],
            capture_output=True, text=True, timeout=4,
        )
        if r.returncode == 0:
            data = json.loads(r.stdout)
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


def _fetch_art(url, callback):
    """Download an art URL to a temp file; call callback(path_or_None) on the main thread."""
    def _work():
        try:
            if url.startswith("file://"):
                path = url[7:]
                if os.path.exists(path):
                    _art_cache[url] = path
                    GLib.idle_add(callback, path)
                else:
                    _art_cache[url] = None
                    GLib.idle_add(callback, None)
                return
            with urllib.request.urlopen(url, timeout=5) as resp:
                data = resp.read()
            fd, path = tempfile.mkstemp(suffix=".jpg")
            with os.fdopen(fd, "wb") as f:
                f.write(data)
            _art_cache[url] = path
            GLib.idle_add(callback, path)
        except Exception:
            _art_cache[url] = None
            GLib.idle_add(callback, None)
        finally:
            _art_pending.discard(url)
    _art_pending.add(url)
    threading.Thread(target=_work, daemon=True).start()
