#!/usr/bin/env python3
"""Drive the quiet shell with real input inside a private nested Hyprland.

Usage: acceptance.py RUNDIR OUTPUT [name-filter]. Prepare with nested.sh first.
Each check reads the shell's IPC state and the fake system's state, so a pass means
the action reached the system and was confirmed, not only that a widget moved.
"""

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
    return json.loads(state_file.read_text())


def set_fake(**values):
    state = fake()
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
AWAKE, NIGHT, THEME, MIC = (1784, 213), (1874, 213), (1784, 283), (1874, 283)
SOUND_GO = (1889, 362)
VOLUME_Y, BRIGHT_Y = 362, 428
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
