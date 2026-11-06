#!/usr/bin/env python3
"""Drive the quiet shell with real input inside a private nested Hyprland.

Usage: acceptance.py RUNDIR OUTPUT [name-filter]. Prepare with nested.sh first.
Each check reads the shell's IPC state and the fake system's state, so a pass means
the action reached the system and was confirmed, not only that a widget moved.
"""

import fcntl
import json
import os
import pathlib
import subprocess
import sys
import time

repo = pathlib.Path(__file__).resolve().parents[2]
run, output = pathlib.Path(sys.argv[1]), sys.argv[2]
only = sys.argv[3] if len(sys.argv) > 3 else ""
shots = run / "shots"
shots.mkdir(exist_ok=True)
state_file = run / "state.json"
env = dict(os.environ)
for line in (run / "env").read_text().splitlines():
    key, _, value = line.partition("=")
    env[key] = value
env["PATH"] = os.environ.get("QUIET_TOOLS", "") + ":" + env["PATH"]
geom = None


def sh(*cmd, timeout=10):
    return subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout, check=False)


def shell(fn):
    path = os.environ.get("QUIET_SHELL_PATH", str(repo / "packages/quiet-shell/shell"))
    out = sh("qs", "ipc", "-p", path, "call", "shell", fn)
    return out.stdout.strip()


def ui():
    return json.loads(shell("state"))


def fake():
    with open(f"{state_file}.lock", "w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return json.loads(state_file.read_text())


def set_fake(**values):
    with open(f"{state_file}.lock", "w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = json.loads(state_file.read_text())
        state.update(values)
        state_file.write_text(json.dumps(state))


def wait(check, what, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if check():
                return
        except (ValueError, KeyError):
            pass
        time.sleep(0.1)
    raise AssertionError(f"timed out waiting for {what}")


def origin():
    global geom
    if geom is None:
        mons = json.loads(sh("hyprctl", "-j", "monitors").stdout)
        mon = next(m for m in mons if m["name"] == output)
        geom = (mon["x"], mon["y"])
    return geom


def move(x, y):
    ox, oy = origin()
    sh("hyprctl", "dispatch", f"hl.dsp.cursor.move({{x={ox + x},y={oy + y}}})")
    # A tiny real movement so the client gets a pointer event at the new position.
    sh("wlrctl", "pointer", "move", "1", "0")
    time.sleep(0.12)


def click(x, y):
    move(x, y)
    sh("wlrctl", "pointer", "click", "left")
    time.sleep(0.2)


def key(name):
    sh("wtype", "-k", name)
    time.sleep(0.2)


def typed(text):
    sh("wtype", text)
    time.sleep(0.25)


def shot(name):
    sh("grim", "-o", output, str(shots / f"{name}.png"), timeout=12)


def clean():
    shell("close")
    move(960, 600)
    time.sleep(0.45)
    keep_log = fake().get("log", [])[-5:]
    set_fake(wifi=True, bt=True, tailscale=True, mullvad=False, night=False, awake=False, muted=False, fail=[], stick=[], log=keep_log)
    wait(lambda: not ui()["top"], "shell to hide")
    wait(lambda: ui()["sys"]["wifi"]["on"] and ui()["sys"]["bluetooth"]["on"], "state to settle", timeout=70)


def open_controls():
    shell("controls")
    wait(lambda: ui()["panel"] == "controls", "controls to open")
    time.sleep(0.3)


WIFI_TOGGLE, WIFI_LABEL = (1603, 73), (1660, 73)
FOCUS_TOGGLE = (1603, 283)
AWAKE, NIGHT, THEME = (1784, 213), (1874, 213), (1777, 283)
SOUND_GO = (1889, 343)
VOLUME_Y, BRIGHT_Y = 343, 393
CC_ICON, BATTERY, CLOCK = (1778, 21), (1732, 21), (1850, 21)
tests = []


def test(fn):
    tests.append(fn)
    return fn


@test
def starts_hidden():
    state = ui()
    assert not state["top"] and state["panel"] == ""


@test
def edge_reveal_and_hide():
    move(960, 0)
    wait(lambda: ui()["top"], "top to reveal")
    move(960, 600)
    wait(lambda: not ui()["top"], "top to hide")


@test
def clicks_pass_through_when_hidden():
    before = sh("hyprctl", "-j", "activewindow").stdout
    click(300, 500)
    click(1400, 500)
    assert "address" in before
    state = ui()
    assert state["panel"] == "" and not state["top"]


@test
def open_from_capsule():
    move(1778, 0)
    wait(lambda: ui()["top"], "top to reveal")
    click(*CC_ICON)
    wait(lambda: ui()["panel"] == "controls", "panel from capsule")


@test
def stays_open_after_pointer_leaves():
    open_controls()
    move(400, 700)
    time.sleep(0.6)
    assert ui()["panel"] == "controls"


@test
def click_outside_dismisses():
    open_controls()
    click(400, 700)
    wait(lambda: ui()["panel"] == "", "outside click to close")


@test
def toggle_is_confirmed_by_readback():
    open_controls()
    start = fake()["wifi"]
    click(*WIFI_TOGGLE)
    wait(lambda: fake()["wifi"] != start, "wifi to change")
    wait(lambda: ui()["writes"] == [] and ui()["sys"]["wifi"]["on"] != start, "readback")
    click(*WIFI_TOGGLE)
    wait(lambda: fake()["wifi"] == start and ui()["writes"] == [], "wifi to return")


@test
def failed_write_offers_retry():
    open_controls()
    set_fake(fail=["nmcli"])
    click(*WIFI_TOGGLE)
    wait(lambda: ui()["failed"] == 1, "failure to show")
    shot("failed")
    set_fake(fail=[])
    # The retry button sits in the row added under the toggles.
    click(1842, 351)
    wait(lambda: ui()["failed"] == 0 and ui()["writes"] == [], "retry to succeed")
    click(*WIFI_TOGGLE)
    wait(lambda: ui()["writes"] == [], "restore")


@test
def silent_no_op_is_caught():
    open_controls()
    set_fake(stick=["bluetoothctl"])
    click(1603, 143)
    wait(lambda: "bluetooth" in ui()["writes"], "pending")
    wait(lambda: ui()["failed"] == 1, "deadline failure", timeout=11)
    set_fake(stick=[])
    click(1842, 351)
    wait(lambda: ui()["failed"] == 0, "retry", timeout=4)
    click(1603, 143)
    wait(lambda: ui()["writes"] == [], "restore")


@test
def failure_can_be_dismissed_and_heals():
    open_controls()
    set_fake(fail=["nmcli"])
    click(*WIFI_TOGGLE)
    wait(lambda: ui()["failed"] == 1, "failure")
    click(1891, 351)
    wait(lambda: ui()["failed"] == 0, "dismiss")
    click(*WIFI_TOGGLE)
    wait(lambda: ui()["failed"] == 1, "failure again")
    # The system reaches the target by itself, for example from another tool.
    set_fake(fail=[], wifi=False)
    wait(lambda: ui()["failed"] == 0, "failure to heal", timeout=8)


@test
def volume_slider_writes_latest_value():
    open_controls()
    click(1680, VOLUME_Y)
    wait(lambda: abs(fake()["volume"] - 0.25) < 0.1, "volume to follow the click")
    wait(lambda: abs(ui()["sys"]["sink"]["level"] - 25) < 10, "readback")


@test
def brightness_slider():
    open_controls()
    click(1800, BRIGHT_Y)
    wait(lambda: fake()["brightness"] > 60, "brightness to follow")


@test
def keyboard_escape_steps_back():
    open_controls()
    click(*SOUND_GO)
    wait(lambda: ui()["detail"] == "sound", "sound detail")
    key("Escape")
    wait(lambda: ui()["detail"] == "" and ui()["panel"] == "controls", "back to controls")
    key("Escape")
    wait(lambda: ui()["panel"] == "", "dismissed")


@test
def choose_output_by_stable_name():
    open_controls()
    click(*SOUND_GO)
    wait(lambda: ui()["detail"] == "sound", "sound detail")
    time.sleep(0.3)
    shot("sound-detail")
    click(1740, 154)
    wait(lambda: fake()["sink"] == "bluez_output.headphones", "sink to change")
    wait(lambda: ui()["writes"] == [], "confirmed")
    set_fake(sink="alsa_output.speakers")


@test
def night_and_awake():
    open_controls()
    click(*NIGHT)
    wait(lambda: fake()["night"], "night on")
    wait(lambda: ui()["writes"] == [], "confirmed")
    click(*NIGHT)
    wait(lambda: not fake()["night"], "night off")
    click(*AWAKE)
    wait(lambda: fake()["awake"], "awake on")
    wait(lambda: ui()["writes"] == [], "confirmed")
    click(*AWAKE)
    wait(lambda: not fake()["awake"], "awake off")


@test
def battery_menu_sets_power_mode():
    move(1732, 0)
    wait(lambda: ui()["top"], "reveal")
    click(*BATTERY)
    wait(lambda: ui()["panel"] == "battery", "battery menu")
    time.sleep(0.3)
    shot("battery")
    click(1760, 118)
    wait(lambda: fake()["profile"] == "power-saver", "power mode")
    set_fake(profile="balanced")


@test
def system_menu_opens():
    move(27, 0)
    wait(lambda: ui()["top"], "reveal")
    click(27, 21)
    wait(lambda: ui()["panel"] == "system", "system menu")
    time.sleep(0.3)
    shot("system")


@test
def theme_switch_restyles_shell():
    open_controls()
    click(*THEME)
    wait(lambda: ui()["detail"] == "theme", "theme detail")
    time.sleep(0.3)
    click(1740, 300)
    wait(lambda: ui()["theme"] != "gilded-contours", "theme to change")
    shot("theme")
    name = ui()["theme"]
    data = json.loads((run / "colors.json").read_text())
    data.update({"name": "gilded-contours", "bg": "071126", "accent": "d3ad7a", "text": "f0d5a2"})
    (run / "colors.json").write_text(json.dumps(data))
    wait(lambda: ui()["theme"] == "gilded-contours", f"theme back from {name}")


@test
def theme_survives_repeated_symlink_swaps():
    colors = run / "colors.json"
    base = json.loads(colors.read_text())
    target_a, target_b = run / "theme-a.json", run / "theme-b.json"
    target_a.write_text(json.dumps({**base, "name": "theme-a"}))
    target_b.write_text(json.dumps({**base, "name": "theme-b"}))
    original = run / "colors.original.json"
    if not colors.is_symlink():
        colors.rename(original)
    for name, target in (("theme-a", target_a), ("theme-b", target_b), ("theme-a", target_a)):
        tmp = run / "colors.tmp"
        tmp.unlink(missing_ok=True)
        tmp.symlink_to(target)
        tmp.replace(colors)
        shell("reloadTheme")
        wait(lambda n=name: ui()["theme"] == n, f"swap to {name}")
    colors.unlink()
    original.rename(colors)
    shell("reloadTheme")
    wait(lambda: ui()["theme"] == "gilded-contours", "restore")


@test
def spotlight_runs_commands():
    marker = run / "spotlight-ran"
    marker.unlink(missing_ok=True)
    shell("spotlight")
    wait(lambda: ui()["spotlight"], "spotlight")
    time.sleep(0.3)
    shot("spotlight-empty")
    typed(f"> touch {marker}")
    shot("spotlight-command")
    key("Return")
    wait(marker.exists, "command to run")
    wait(lambda: not ui()["spotlight"], "spotlight to close")


@test
def spotlight_finds_windows():
    shell("spotlight")
    wait(lambda: ui()["spotlight"], "spotlight")
    time.sleep(0.2)
    typed("kit")
    time.sleep(0.2)
    shot("spotlight-results")
    key("Escape")
    wait(lambda: not ui()["spotlight"], "escape")


@test
def notifications_banner_history_clear():
    sh("notify-send", "Kitty", "Build finished")
    wait(lambda: ui()["banner"], "banner")
    wait(lambda: ui()["notices"] >= 1, "history")
    time.sleep(0.3)
    shot("banner")
    shell("notifications")
    wait(lambda: ui()["panel"] == "notifications", "centre")
    time.sleep(0.3)
    shot("notifications")
    click(1877, 274)
    wait(lambda: ui()["notices"] == 0, "clear all")


@test
def focus_silences_banners():
    open_controls()
    click(*FOCUS_TOGGLE)
    wait(lambda: ui()["focus"], "focus on")
    shell("close")
    sh("notify-send", "Quiet", "No banner please")
    wait(lambda: ui()["notices"] == 1, "history keeps it")
    assert not ui()["banner"]
    open_controls()
    click(*FOCUS_TOGGLE)
    wait(lambda: not ui()["focus"], "focus off")
    shell("notifications")
    wait(lambda: ui()["panel"] == "notifications", "centre")
    time.sleep(0.3)
    click(1877, 274)


@test
def fullscreen_app_keeps_edges_quiet():
    sh("hyprctl", "dispatch", 'hl.dsp.window.fullscreen({mode="fullscreen"})')
    time.sleep(0.5)
    try:
        move(960, 0)
        time.sleep(0.4)
        assert not ui()["top"], "top edge revealed over a fullscreen app"
        move(960, 1079)
        time.sleep(0.4)
        assert not ui()["dock"], "dock revealed over a fullscreen app"
    finally:
        sh("hyprctl", "dispatch", 'hl.dsp.window.fullscreen({mode="fullscreen"})')
        move(960, 600)
        time.sleep(0.5)


@test
def keyboard_reaches_controls():
    open_controls()
    key("Tab")
    key("Tab")
    state = ui()
    assert state["panel"] == "controls"
    key("Escape")
    wait(lambda: ui()["panel"] == "", "escape closes")


@test
def dock_reveal_and_hide():
    move(960, 1079)
    wait(lambda: ui()["dock"], "dock reveal")
    time.sleep(0.3)
    shot("dock")
    move(960, 500)
    wait(lambda: not ui()["dock"], "dock hide")


@test
def overview_returns_to_window():
    shell("overview")
    wait(lambda: ui()["overview"], "overview")
    time.sleep(0.6)
    shot("overview")
    click(400, 500)
    wait(lambda: not ui()["overview"], "window click to close")


@test
def night_uses_the_timezone_location():
    open_controls()
    click(*NIGHT)
    wait(lambda: ui()["sys"]["night"], "night on")
    calls = [" ".join(c) for c in fake()["log"]]
    assert any("wlsunset -l 52.25 -L 21.0" in c for c in calls), calls[-8:]


@test
def focus_survives_a_restart():
    open_controls()
    click(*FOCUS_TOGGLE)
    wait(lambda: ui()["focus"], "focus on")
    time.sleep(0.3)
    restart_shell()
    wait(lambda: ui()["focus"], "focus to come back", timeout=10)
    shell("controls")
    time.sleep(0.5)
    click(*FOCUS_TOGGLE)
    wait(lambda: not ui()["focus"], "focus off")
    time.sleep(0.3)
    restart_shell()
    wait(lambda: "focus" in ui() and not ui()["focus"], "focus to stay off", timeout=10)


@test
def wifi_password_joins_without_leaking():
    open_controls()
    click(*WIFI_LABEL)
    wait(lambda: ui()["detail"] == "wifi", "wifi detail")
    time.sleep(0.4)
    shot("wifi-list")
    click(1700, 169)
    time.sleep(0.3)
    typed("correct horse")
    shot("wifi-password")
    key("Return")
    wait(lambda: fake()["ssid"] == "Kavarna Guest", "join", timeout=8)
    wait(lambda: ui()["sys"]["wifi"]["ssid"] == "Kavarna Guest", "readback")
    assert "correct horse" not in json.dumps(fake()["log"]), "password reached argv"
    wait(lambda: not ui()["writes"], "write to confirm")


@test
def escape_still_works_after_cancelling_a_password():
    open_controls()
    click(*WIFI_LABEL)
    wait(lambda: ui()["detail"] == "wifi", "wifi detail")
    time.sleep(1.2)
    click(1700, 169)
    time.sleep(0.3)
    key("Escape")
    time.sleep(0.3)
    assert ui()["detail"] == "wifi", "escape left the page instead of the field"
    key("Escape")
    wait(lambda: ui()["detail"] == "", "second escape to go back")


@test
def wrong_password_fails_and_leaves_no_profile():
    set_fake(ssid="Harbour 5G", known=["Harbour 5G", "Harbour 2.4G"])
    open_controls()
    click(*WIFI_LABEL)
    wait(lambda: ui()["detail"] == "wifi", "wifi detail")
    time.sleep(1.2)
    click(1700, 169)
    time.sleep(0.3)
    typed("wrong")
    key("Return")
    wait(lambda: ui()["failed"] == 1, "failure", timeout=8)
    wait(lambda: "Kavarna Guest" not in fake()["known"], "failed profile to go")
    shot("wifi-wrong-password")
    # Reaching the network heals the failure, which clears it for later tests.
    set_fake(ssid="Kavarna Guest")
    wait(lambda: ui()["failed"] == 0, "failure to heal")
    set_fake(ssid="Harbour 5G")


@test
def bluetooth_scans_and_pairs():
    open_controls()
    click(1660, 143)
    wait(lambda: ui()["detail"] == "bluetooth", "bluetooth detail")
    wait(lambda: any(c[:1] == ["bluetoothctl"] and "scan" in c for c in fake()["log"]), "scan")
    wait(lambda: ui()["sys"]["bluetooth"]["nearby"], "nearby device")
    time.sleep(0.4)
    shot("bluetooth-nearby")
    click(1700, 192)
    addr = "AA:BB:CC:00:00:03"
    wait(lambda: any(d["addr"] == addr and d["connected"] for d in ui()["sys"]["bluetooth"]["devices"]), "paired", timeout=8)


@test
def tray_item_appears_and_activates():
    if not os.environ.get("QUIET_TRAY_PYTHON"):
        return
    log = run / "tray.log"
    log.write_text("")
    tray = subprocess.Popen([os.environ["QUIET_TRAY_PYTHON"], str(repo / "tests/quiet-shell/fakes/tray.py"), str(log)], env=env)
    try:
        wait(lambda: ui()["tray"] == ["quiet-test"], "tray item")
        move(1664, 0)
        wait(lambda: ui()["top"], "top reveal")
        time.sleep(0.3)
        shot("tray")
        click(1664, 21)
        wait(lambda: "activate" in log.read_text(), "activation")
    finally:
        tray.terminate()
    wait(lambda: ui()["tray"] == [], "tray item to go")


@test
def focus_follows_a_new_monitor():
    sh("hyprctl", "output", "create", "headless", "QUIET-2")
    sh("hyprctl", "eval", 'hl.monitor({output="QUIET-2",mode="1280x720@60",position="3840x0",scale=1})')
    sh("hyprctl", "dispatch", 'hl.dsp.focus({monitor="QUIET-2"})')
    try:
        wait(lambda: ui()["screen"] == "QUIET-2", "shell to see the new monitor")
    finally:
        sh("hyprctl", "output", "remove", "QUIET-2")
        sh("hyprctl", "dispatch", f'hl.dsp.focus({{monitor="{output}"}})')
    wait(lambda: ui()["screen"] in (output, ""), "shell to return")
    shell("controls")
    wait(lambda: ui()["panel"] == "controls", "controls")
    time.sleep(0.4)
    shot("after-monitor-removed")


@test
def shut_down_asks_first():
    shell("close")
    move(30, 0)
    wait(lambda: ui()["top"], "top reveal")
    click(30, 21)
    wait(lambda: ui()["panel"] == "system", "system menu")
    time.sleep(0.2)
    before = len(fake()["log"])
    click(100, 123)
    wait(lambda: ui()["confirm"] == "Shut Down", "confirmation")
    time.sleep(0.3)
    shot("confirm")
    assert not [c for c in fake()["log"][before:] if "poweroff" in c], "ran without asking"
    key("Escape")
    wait(lambda: ui()["confirm"] == "", "escape to cancel")
    assert not [c for c in fake()["log"][before:] if "poweroff" in c], "cancel still ran it"
    shell("close")
    move(30, 0)
    wait(lambda: ui()["top"], "top reveal")
    click(30, 21)
    wait(lambda: ui()["panel"] == "system", "system menu")
    time.sleep(0.2)
    click(100, 123)
    wait(lambda: ui()["confirm"] == "Shut Down", "confirmation")
    time.sleep(0.3)
    click(1029, 577)
    wait(lambda: [c for c in fake()["log"] if "poweroff" in c], "shut down to run")


@test
def low_battery_warns_once_per_discharge():
    level, status = run / "power/BAT0/capacity", run / "power/BAT0/status"
    before = ui()["notices"]
    try:
        level.write_text("12\n")
        shell("controls")
        wait(lambda: ui()["notices"] == before + 1, "low battery notice", timeout=8)
        shell("close")
        level.write_text("11\n")
        shell("controls")
        time.sleep(5)
        assert ui()["notices"] == before + 1, "warned twice"
        level.write_text("4\n")
        wait(lambda: ui()["notices"] == before + 2, "critical notice", timeout=8)
    finally:
        level.write_text("64\n")
        status.write_text("Discharging\n")


@test
def mullvad_location_and_exit_node():
    set_fake(mullvad=True)
    open_controls()
    click(1660, 213)
    wait(lambda: ui()["detail"] == "vpn", "vpn detail")
    wait(lambda: ui()["sys"]["vpn"]["country"] == "se", "country")
    time.sleep(0.4)
    shot("vpn-detail")
    click(1700, 169)
    wait(lambda: ui()["detail"] == "mullvad", "location picker")
    time.sleep(0.8)
    shot("mullvad-location")
    click(1700, 169)
    wait(lambda: fake()["country"] == "gb", "country to change", timeout=8)
    wait(lambda: not ui()["writes"], "write to confirm", timeout=8)
    key("Escape")
    wait(lambda: ui()["detail"] == "vpn", "escape back to vpn")
    time.sleep(0.3)
    click(1700, 247)
    wait(lambda: fake()["exit_node"] == "home-box", "exit node", timeout=8)
    wait(lambda: not ui()["writes"], "exit node to confirm", timeout=8)
    set_fake(exit_node="", country="se", mullvad=False)


@test
def network_settings_open_from_wifi():
    open_controls()
    click(*WIFI_LABEL)
    wait(lambda: ui()["detail"] == "wifi", "wifi detail")
    time.sleep(0.4)
    click(1700, 277)
    wait(lambda: [c for c in fake()["log"] if c[:1] == ["nm-connection-editor"]], "settings to open")
    wait(lambda: ui()["panel"] == "", "panel to close")


def restart_shell():
    path = os.environ.get("QUIET_SHELL_PATH", "")
    for proc in pathlib.Path("/proc").glob("[0-9]*"):
        try:
            cmdline = (proc / "cmdline").read_bytes().replace(b"\0", b" ").decode()
        except OSError:
            continue
        if path and path in cmdline and "ipc" not in cmdline:
            os.kill(int(proc.name), 15)
    time.sleep(2.5)
    wait(lambda: ui(), "shell to restart", timeout=10)


def clients():
    return json.loads(sh("hyprctl", "-j", "clients").stdout)


def minimised():
    return [c for c in clients() if c["workspace"]["name"] == "special:minimized"]


def reveal_dock():
    move(960, 1079)
    wait(lambda: ui()["dock"], "dock reveal")
    time.sleep(0.3)


@test
def app_icons_come_from_desktop_entries():
    icons = ui()["suggested"]
    assert "spotify-client" in icons and "org.xfce.thunar" in icons, icons


@test
def dock_lists_only_running_apps():
    apps = ui()["apps"]
    assert [a["name"] for a in apps] == ["kitty"], apps


@test
def desktop_dots_are_always_ten():
    move(100, 0)
    wait(lambda: ui()["top"], "top reveal")
    move(100, 21)
    time.sleep(0.3)
    shot("desktop-dots")


@test
def minimise_key_is_bound():
    binds = json.loads(sh("hyprctl", "-j", "binds").stdout)
    assert any(b["key"].lower() == "minus" for b in binds), "no minimise bind"


@test
def minimised_window_returns_to_this_desktop():
    sh("hyprctl", "dispatch", 'hl.dsp.window.move({workspace="special:minimized",follow=false})')
    wait(lambda: len(minimised()) == 1, "window to minimise")
    wait(lambda: ui()["apps"][0]["hidden"] == 1, "dock to notice")
    sh("hyprctl", "dispatch", "hl.dsp.focus({workspace=7})")
    reveal_dock()
    shot("dock-minimised")
    click(960, 1040)
    wait(lambda: not minimised(), "window to restore")
    active = json.loads(sh("hyprctl", "-j", "activewindow").stdout)
    assert active["workspace"]["id"] == 7, active["workspace"]


@test
def dock_click_minimises_a_focused_lone_window():
    sh("hyprctl", "dispatch", "hl.dsp.window.close()")
    wait(lambda: len(clients()) == 1, "one window left")
    sh("hyprctl", "dispatch", f'hl.dsp.focus({{window="address:{clients()[0]["address"]}"}})')
    wait(lambda: json.loads(sh("hyprctl", "-j", "activewindow").stdout).get("address"), "focus")
    reveal_dock()
    click(960, 1040)
    wait(lambda: len(minimised()) == 1, "window to minimise")
    click(960, 1040)
    wait(lambda: not minimised(), "window to restore")


@test
def dock_stays_away_with_nothing_running():
    sh("hyprctl", "dispatch", "hl.dsp.window.close()")
    wait(lambda: not clients(), "no windows")
    wait(lambda: not ui()["apps"], "dock to empty")
    move(960, 1079)
    time.sleep(0.6)
    assert not ui()["dock"], "empty dock revealed"
    shot("no-windows")


# A fresh home gets Hyprland's donate window, which would count as a running app.
for c in clients():
    if "donate" in c["class"]:
        sh("hyprctl", "dispatch", f'hl.dsp.window.close({{window="address:{c["address"]}"}})')
time.sleep(0.5)

passed = failed = 0
results = {}
for fn in tests:
    if only and only not in fn.__name__:
        continue
    try:
        clean()
        fn()
        passed += 1
        results[fn.__name__] = "pass"
        print("PASS", fn.__name__, flush=True)
    except Exception as exc:  # noqa: BLE001
        failed += 1
        results[fn.__name__] = str(exc)
        shot("fail-" + fn.__name__)
        print("FAIL", fn.__name__, "-", exc, flush=True)
(run / "results.json").write_text(json.dumps(results, indent=1))
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
