#!/usr/bin/env python3
"""Drive the quiet shell with real input inside a private nested Hyprland.

Usage: acceptance.py RUNDIR OUTPUT [name-filter, | between several]. Prepare with nested.sh first.
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

from session_processes import terminate_shell

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
    out = sh("qs", "ipc", "-p", path, "call", "shell", *fn.split())
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
# The App icons rows under the eight themes in the Theme detail, and the dock's only app.
ICONS_COLOUR, ICONS_MONO = (1740, 392), (1740, 426)
DOCK_FIRST = (960, 1040)
# The first button of an agent request banner (Take control).
AGENT_TAKE = (1693, 123)
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
    # Below the calendar and its "Up next" agenda.
    click(1876, 379)
    wait(lambda: ui()["notices"] == 0, "clear all")


def agent_event(**event):
    with (run / "agent-events.jsonl").open("a", encoding="utf-8") as stream:
        stream.write(json.dumps({"at": time.time(), **event}) + "\n")


@test
def agent_request_banner_runs_its_command():
    # A sign-in request from Agent Desktop: a banner with the event's own commands.
    # Clicking runs that command; answering elsewhere takes the banner away.
    agent_event(event="human_requested", session="s1", reason="Sign in to the console", login=True, take_command="nm-connection-editor agent-take s1", paste_command="nm-connection-editor agent-paste s1")
    wait(lambda: ui()["agentRequests"] == 1 and ui()["banner"], "agent banner")
    time.sleep(0.3)
    shot("agent-request")
    click(*AGENT_TAKE)
    wait(lambda: ["nm-connection-editor", "agent-take", "s1"] in fake()["log"], "take command ran")
    agent_event(event="control_taken", session="s1")
    wait(lambda: ui()["agentRequests"] == 0, "request settled")
    # Requests to use the person's own screen are left to the client: no banner.
    agent_event(event="host_requested", request="h1", reason="Open the router page", minutes=15, approve_command="nm-connection-editor agent-approve", deny_command="nm-connection-editor agent-deny")
    agent_event(event="human_requested", session="s2", reason="Solve the CAPTCHA", take_command="nm-connection-editor agent-take s2")
    wait(lambda: ui()["agentRequests"] == 1, "only the session request")
    assert ["nm-connection-editor", "agent-approve"] not in fake()["log"], "nothing is approved without a click"
    agent_event(event="human_withdrawn", session="s2")
    wait(lambda: ui()["agentRequests"] == 0, "withdrawn request settled")


@test
def notifications_closed_by_app_can_still_be_cleared():
    # The live QObject disappears when an app withdraws its notification. History
    # must remain usable alongside a notification that is still live.
    notice = sh("notify-send", "-p", "Withdrawn", "Keep this in history").stdout.strip()
    wait(lambda: ui()["notices"] >= 1, "history")
    reply = sh("dbus-send", "--session", "--dest=org.freedesktop.Notifications", "--type=method_call", "--print-reply", "/org/freedesktop/Notifications", "org.freedesktop.Notifications.CloseNotification", f"uint32:{notice}")
    assert reply.returncode == 0, reply.stderr
    time.sleep(0.2)
    before = ui()["notices"]
    sh("notify-send", "Still live", "Clear both")
    wait(lambda: ui()["notices"] == before + 1, "live notice")
    shell("notifications")
    wait(lambda: ui()["panel"] == "notifications", "centre")
    time.sleep(0.3)
    typed("c")
    wait(lambda: ui()["notices"] == 0 and not ui()["banner"], "clear withdrawn and live notices")


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
    # Below the calendar and its "Up next" agenda.
    click(1876, 379)


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
def app_icons_choose_colour_or_monochrome():
    # nested.sh keeps the shell's state in the run.
    icons = run / "state/quiet-shell/icons"

    def choose(at, mono):
        open_controls()
        click(*THEME)
        wait(lambda: ui()["detail"] == "theme", "theme detail")
        time.sleep(0.3)
        click(*at)
        wait(lambda: ui()["monoIcons"] == mono, "monochrome icons" if mono else "colour icons")
        wait(lambda: icons.exists() and icons.read_text().strip() == ("mono" if mono else "colour"), "the choice to be saved")

    choose(ICONS_COLOUR, False)
    shot("app-icons-colour")
    restart_shell()
    wait(lambda: "monoIcons" in ui() and not ui()["monoIcons"], "colour to come back", timeout=10)
    choose(ICONS_MONO, True)
    shot("app-icons-mono")
    clean()
    move(960, 1079)
    wait(lambda: ui()["dock"], "dock reveal")
    time.sleep(0.3)
    move(*DOCK_FIRST)
    time.sleep(0.4)
    shot("dock-icon-lit")


@test
def focus_toggles_from_its_label():
    open_controls()
    before = ui()["focus"]
    click(1650, 282)
    wait(lambda: ui()["focus"] != before, "the label to toggle focus")
    click(1650, 282)
    wait(lambda: ui()["focus"] == before, "the label to toggle it back")


@test
def super_tab_switches_with_real_key_order():
    addresses = [c["address"] for c in clients() if c["workspace"]["id"] > 0][:2]
    taps = [["S+", "T+", "T-", "S-"], ["S+", "T+", "15", "T-", "15", "S-"], ["S+", "T+", "40", "S-", "T-"]] * 3
    for steps in taps + [["S+", "T+", "60", "T-", "600", "S-"]]:
        sh("hyprctl", "dispatch", f'hl.dsp.focus({{window="address:{addresses[0]}"}})')
        time.sleep(0.3)
        sh("hyprctl", "dispatch", f'hl.dsp.focus({{window="address:{addresses[1]}"}})')
        time.sleep(0.3)
        sh(sys.executable, str(repo / "tests/quiet-shell/chord.py"), *steps)
        wait(lambda: json.loads(sh("hyprctl", "-j", "activewindow").stdout)["address"] == addresses[0], "the switch")
        assert ui()["switcher"] == -1, "the switcher must not stay open"


@test
def overview_tab_walks_the_desktops():
    desk = lambda: json.loads(sh("hyprctl", "activeworkspace", "-j").stdout)["id"]
    start = desk()
    shell("overview")
    wait(lambda: ui()["overview"], "overview")
    time.sleep(0.4)
    key("Tab")
    wait(lambda: desk() != start, "Tab to change desktop")
    shot("overview-tab")
    sh("wtype", "-M", "shift", "-k", "Tab", "-m", "shift")
    wait(lambda: desk() == start, "Shift+Tab to come back")
    key("Return")
    wait(lambda: not ui()["overview"], "Return to close the overview")


@test
def control_centre_letters_press_their_controls():
    open_controls()
    key("n")
    wait(lambda: fake()["night"], "n to turn night mode on")
    wait(lambda: ui()["writes"] == [], "confirmed")
    key("n")
    wait(lambda: not fake()["night"], "n to turn night mode off")
    wait(lambda: ui()["writes"] == [], "confirmed")
    time.sleep(0.2)
    shot("control-letters")
    key("w")
    wait(lambda: ui()["detail"] == "wifi", "w to open Wi-Fi")
    assert fake()["wifi"], "a letter must not drop the connection"
    # Letters mean nothing inside a detail view, where a list has the keyboard.
    key("n")
    time.sleep(0.5)
    assert not fake()["night"], "n must not act behind the details"


@test
def control_centre_works_from_the_keyboard():
    open_controls()
    # The first stop is the Wi-Fi pill, not a desktop dot in the bar behind the panel.
    key("Tab")
    key("Return")
    wait(lambda: ui()["detail"] == "wifi", "Tab then Return to open Wi-Fi")
    key("Escape")
    wait(lambda: ui()["detail"] == "", "Escape to leave Wi-Fi")
    # Letters still work after focus has been on a control that went away.
    key("n")
    wait(lambda: fake()["night"], "n after tabbing")
    wait(lambda: ui()["writes"] == [], "confirmed")
    key("n")
    wait(lambda: not fake()["night"], "n off")
    wait(lambda: ui()["writes"] == [], "confirmed")
    # The next stop is the round switch on the same pill.
    key("Tab")
    key("Tab")
    key("Return")
    wait(lambda: not fake()["wifi"], "Tab to the Wi-Fi switch")
    wait(lambda: ui()["writes"] == [], "confirmed")


@test
def buds_connect_with_a_letter_and_set_noise_control():
    addr = "AA:BB:CC:00:00:09"
    devices = fake()["devices"]
    set_fake(buds=addr, buds_mode="off", devices={**devices, addr: ["Galaxy Buds", False]})
    try:
        open_controls()
        wait(lambda: ui()["sys"]["bluetooth"]["buds"], "the buds to be found", timeout=8)
        key("b")
        wait(lambda: fake()["devices"][addr][1], "b to connect the buds")
        wait(lambda: ui()["writes"] == [], "connection confirmed", timeout=10)
        time.sleep(2.6)
        shot("buds")
        # The row under the pill, with no failure rows above it.
        click(1853, 512)
        wait(lambda: fake()["buds_mode"] == "anc", "ANC")
        wait(lambda: ui()["writes"] == [], "ANC confirmed", timeout=10)
        time.sleep(0.3)
        shot("buds-anc")
        key("b")
        wait(lambda: not fake()["devices"][addr][1], "b to disconnect the buds")
    finally:
        set_fake(buds=None, devices=devices)


@test
def overview_drags_a_window_to_another_desktop():
    here = json.loads(sh("hyprctl", "-j", "activeworkspace").stdout)["id"]
    windows = [c for c in clients() if c["workspace"]["id"] == here]
    assert len(windows) == 2, windows
    used = sorted(w["id"] for w in json.loads(sh("hyprctl", "-j", "workspaces").stdout) if 0 < w["id"] <= 10)
    empty = next(i for i in range(1, 11) if i not in used)
    desks = sorted(used + [empty])
    shell("overview")
    wait(lambda: ui()["overview"], "overview")
    time.sleep(0.5)
    ox, oy = origin()
    # The first tile of two side by side, and the empty desktop in the row above.
    tile = (ox + 408, oy + 573)
    desk = (ox + 48 + desks.index(empty) * 184 + 85, oy + 72)
    extra = dict(QUIET_DRAG_SHOT=str(shots / "overview-drag.png"), QUIET_DRAG_OUTPUT=output)
    subprocess.run([sys.executable, str(repo / "tests/quiet-shell/drag.py"), *map(str, tile + desk)], env={**env, **extra}, check=True, timeout=30)
    moved = lambda: [c for c in clients() if c["workspace"]["id"] == empty]
    wait(lambda: len(moved()) == 1, "the window to reach the empty desktop")
    assert ui()["overview"], "dragging must leave the overview open"
    shell("close")
    sh("hyprctl", "dispatch", f'hl.dsp.window.move({{workspace={here},window="address:{moved()[0]["address"]}",follow=false}})')
    wait(lambda: not moved(), "the window to return")


@test
def password_requests_appear_in_the_shell():
    shell("testAuth")
    wait(lambda: ui()["auth"] != "", "the request")
    time.sleep(0.4)
    shot("auth")
    click(100, 500)
    assert ui()["auth"] != "", "a click outside must not dismiss it"
    click(960, 540)
    typed("wrong")
    key("Return")
    wait(lambda: ui()["authFailed"], "the failure")
    time.sleep(0.3)
    shot("auth-failed")
    typed("correct horse")
    key("Return")
    wait(lambda: ui()["auth"] == "", "the request to finish")


@test
def escape_cancels_a_password_request():
    shell("testAuth")
    wait(lambda: ui()["auth"] != "", "the request")
    time.sleep(0.3)
    key("Escape")
    wait(lambda: ui()["auth"] == "", "escape to cancel")


@test
def lock_screen_battery_shows_only_when_it_matters():
    script = repo / "home/files/hypr/lock-status.sh"
    level, status = run / "power/BAT0/capacity", run / "power/BAT0/status"
    try:
        assert sh("bash", str(script), "battery").stdout.strip() == ""
        level.write_text("15\n")
        assert sh("bash", str(script), "battery").stdout.strip() == "15%"
        status.write_text("Charging\n")
        assert sh("bash", str(script), "battery").stdout.strip() == "15% · Charging"
        assert sh("bash", str(script), "media").stdout == ""
    finally:
        level.write_text("64\n")
        status.write_text("Discharging\n")


@test
def only_the_chosen_network_shows_progress():
    set_fake(ssid="Harbour 5G", known=["Harbour 5G", "Harbour 2.4G", "Open Cafe"], stick=["nmcli"])
    open_controls()
    click(*WIFI_LABEL)
    wait(lambda: ui()["detail"] == "wifi", "wifi detail")
    time.sleep(1.2)
    nets = ui()["sys"]["wifi"]["networks"]
    assert nets[0]["name"] == "Harbour 5G" and nets[0]["active"], nets
    assert [n["name"] for n in nets].count("Harbour 5G") == 1, nets
    shot("wifi-connected")
    click(1700, 123)
    wait(lambda: ui()["joining"] == "Harbour 2.4G", "the chosen network to be joining")
    time.sleep(0.3)
    shot("wifi-joining")
    set_fake(stick=[], ssid="Harbour 2.4G")
    wait(lambda: ui()["joining"] == "", "the join to finish", timeout=8)
    wait(lambda: ui()["sys"]["wifi"]["networks"][0]["name"] == "Harbour 2.4G", "the new network on top")
    set_fake(ssid="Harbour 5G", known=["Harbour 5G", "Harbour 2.4G"])
    key("Escape")
    wait(lambda: not ui()["writes"], "write to confirm")


@test
def escape_still_works_after_cancelling_a_password():
    set_fake(ssid="Harbour 5G", known=["Harbour 5G", "Harbour 2.4G"])
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


def mullvad_memory(**picks):
    now = int(time.time() * 1000)
    path = run / "state/quiet-shell/mullvad.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"picks": {code: {"n": n, "t": now} for code, n in picks.items()}}))
    time.sleep(0.5)


@test
def mullvad_keys_and_recent_use_order():
    mullvad_memory(gb=5, se=1)
    set_fake(mullvad=False, country="se")
    open_controls()
    key("v")
    wait(lambda: ui()["detail"] == "vpn", "v to open VPN")
    time.sleep(0.3)
    shot("vpn-key-hints")
    key("m")
    wait(lambda: fake()["mullvad"], "m to connect Mullvad")
    wait(lambda: not ui()["writes"], "Mullvad confirmed")
    key("t")
    wait(lambda: not fake()["tailscale"], "t to switch Tailscale off")
    wait(lambda: not ui()["writes"], "Tailscale confirmed")
    key("t")
    wait(lambda: fake()["tailscale"], "t to switch Tailscale on")
    wait(lambda: not ui()["writes"], "Tailscale back")
    key("l")
    wait(lambda: ui()["detail"] == "mullvad", "l to open the location list")
    wait(lambda: ui()["countries"] == ["gb", "se", "al"], "most used first")
    time.sleep(0.4)
    # k stops at the top rather than wrapping round to the bottom.
    key("k")
    key("j")
    key("j")
    key("k")
    key("j")
    shot("mullvad-cursor")
    key("Return")
    wait(lambda: fake()["country"] == "al", "Enter to pick the row under the cursor", timeout=8)
    wait(lambda: not ui()["writes"], "location confirmed", timeout=8)
    assert ui()["countries"] == ["gb", "se", "al"], "rows moved under the cursor"
    memory = json.loads((run / "state/quiet-shell/mullvad.json").read_text())
    assert memory["picks"]["al"]["n"] == 1, memory
    key("Escape")
    wait(lambda: ui()["detail"] == "vpn", "escape back to vpn")
    time.sleep(0.2)
    key("l")
    wait(lambda: ui()["countries"] == ["gb", "al", "se"], "the new pick to rank above an equal older one")


@test
def spotlight_controls_mullvad():
    mullvad_memory(gb=5)
    set_fake(mullvad=False, country="se")
    spotlight("mullvad")
    assert any(r.endswith(": Mullvad") for r in ui()["results"]), ui()["results"]
    key("Return")
    wait(lambda: fake()["mullvad"], "Enter to connect Mullvad")
    wait(lambda: not ui()["writes"], "Mullvad confirmed")
    spotlight("mullvad ")
    wait(lambda: ui()["results"][:3] == ["Mullvad: UK", "Mullvad: Albania", "Mullvad: Sweden"], "countries by use")
    shot("spotlight-mullvad")
    spotlight("mullvad britain")
    wait(lambda: ui()["results"] == ["Mullvad: UK"], "a country under its other name")
    spotlight("mullvad alb")
    wait(lambda: ui()["results"][:1] == ["Mullvad: Albania"], "country by name")
    key("Return")
    wait(lambda: fake()["country"] == "al", "Enter to switch country", timeout=8)
    wait(lambda: not ui()["writes"], "location confirmed", timeout=8)
    spotlight("mullvad disc")
    wait(lambda: ui()["results"] == ["Mullvad: Disconnect"], "the switch by its word")
    key("Return")
    wait(lambda: not fake()["mullvad"], "Enter to disconnect")
    wait(lambda: not ui()["writes"], "disconnect confirmed")


@test
def mullvad_location_and_exit_node():
    mullvad_memory()
    set_fake(mullvad=True, country="se")
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


@test
def hardware_keys_show_the_hud():
    start = fake()["volume"]
    shell("volume 5")
    wait(lambda: (ui()["hud"] or {}).get("kind") == "volume", "volume hud")
    wait(lambda: abs(ui()["hud"]["level"] - round((start + 0.05) * 100)) <= 1, "hud to match")
    assert abs(fake()["volume"] - (start + 0.05)) < 0.011, fake()["volume"]
    time.sleep(0.3)
    shot("hud")
    shell("mute")
    wait(lambda: ui()["hud"]["muted"], "mute shown")
    assert fake()["muted"]
    shell("mute")
    wait(lambda: not ui()["hud"]["muted"], "unmute shown")
    bright = fake()["brightness"]
    shell("brightness -5")
    wait(lambda: ui()["hud"]["kind"] == "brightness", "brightness hud")
    assert fake()["brightness"] == bright - 5 and ui()["hud"]["level"] == bright - 5
    wait(lambda: ui()["hud"] is None, "hud to leave", timeout=4)


@test
def switcher_moves_between_recent_windows():
    first = ui()["active"]
    windows = ui()["recent"]
    assert len(windows) >= 2, windows
    addresses = [c["address"] for c in clients() if c["workspace"]["id"] > 0]
    sh("hyprctl", "dispatch", f'hl.dsp.focus({{window="address:{addresses[0]}"}})')
    time.sleep(0.3)
    sh("hyprctl", "dispatch", f'hl.dsp.focus({{window="address:{addresses[1]}"}})')
    time.sleep(0.3)
    shell("switcher 1")
    wait(lambda: ui()["switcher"] == 1, "switcher on the previous window")
    order = ["0x" + a.removeprefix("0x") for a in ui()["recent"]]
    assert order[:2] == [addresses[1], addresses[0]], (order, addresses)
    time.sleep(0.3)
    shot("switcher")
    shell("switcherDone")
    wait(lambda: ui()["switcher"] == -1, "switcher to close")
    wait(lambda: json.loads(sh("hyprctl", "-j", "activewindow").stdout)["address"] == addresses[0], "the other window to focus")
    shell("switcher 1")
    wait(lambda: ui()["switcher"] == 1, "open again")
    key("Escape")
    wait(lambda: ui()["switcher"] == -1, "escape to cancel")
    active = json.loads(sh("hyprctl", "-j", "activewindow").stdout)
    assert active["address"] == addresses[0], "escape must not switch"


def spotlight(text):
    shell("close")
    time.sleep(0.2)
    shell("spotlight")
    wait(lambda: ui()["spotlight"], "spotlight")
    time.sleep(0.3)
    typed(text)
    time.sleep(0.5)


@test
def spotlight_calculates_and_copies():
    spotlight("2+3*4")
    shot("spotlight-calculator")
    key("Return")
    wait(lambda: fake().get("clipboard") == "14", "result on the clipboard")
    spotlight("20% * 50")
    key("Return")
    wait(lambda: fake().get("clipboard") == "10", "percent")


@test
def spotlight_runs_system_actions():
    spotlight("lock")
    shot("spotlight-system")
    key("Return")
    wait(lambda: ["hyprlock"] in fake()["log"], "lock")
    spotlight("shut")
    key("Return")
    wait(lambda: ui()["confirm"] == "Shut Down", "spotlight to ask first")
    assert not [c for c in fake()["log"] if "poweroff" in c][1:], "ran without asking"
    key("Escape")
    wait(lambda: ui()["confirm"] == "", "cancel")


@test
def spotlight_finds_files_and_the_web():
    spotlight("report")
    wait(lambda: any(c[:1] == ["fd"] for c in fake()["log"]), "file search")
    time.sleep(0.4)
    shot("spotlight-files")
    key("Return")
    wait(lambda: any(c[:1] == ["xdg-open"] and c[1].endswith("quiet-report.txt") for c in fake()["log"]), "file to open")
    spotlight("zzqq what")
    key("Return")
    wait(lambda: any(c[:1] == ["xdg-open"] and "zzqq%20what" in c[1] for c in fake()["log"]), "web search")


def ctrl(name):
    sh("wtype", "-M", "ctrl", "-k", name, "-m", "ctrl")
    time.sleep(0.2)


@test
def spotlight_converts_units_and_money():
    spotlight("5 km in mi")
    shot("spotlight-units")
    key("Return")
    wait(lambda: fake().get("clipboard") == "3.1069", "kilometres in miles")
    spotlight("100 usd to pln")
    wait(lambda: ui()["results"][:1] == ["Conversion: 390.91 PLN"], "rates from the fake bank")
    shot("spotlight-currency")
    key("Return")
    wait(lambda: fake().get("clipboard") == "390.91", "dollars in zloty")


@test
def spotlight_file_shortcuts():
    # Earlier tests may have made it the top hit, so look for it in any group.
    spotlight("report")
    wait(lambda: ui()["results"][0].endswith(": quiet-report.txt"), "the file first")
    shot("spotlight-file-hint")
    ctrl("Return")
    wait(lambda: any(c[:1] == ["xdg-open"] and c[1].endswith("/notes") for c in fake()["log"]), "its folder to open")
    spotlight("report")
    wait(lambda: ui()["results"][0].endswith(": quiet-report.txt"), "the file again")
    ctrl("c")
    wait(lambda: str(fake().get("clipboard", "")).endswith("notes/quiet-report.txt"), "its path to copy")


@test
def spotlight_learns_what_a_query_means():
    spotlight("lo")
    results = ui()["results"]
    assert results.index("System: Log Out") > results.index("System: Lock Screen"), results
    for _ in range(results.index("System: Log Out")):
        key("Down")
    key("Return")
    wait(lambda: ui()["confirm"] == "Log Out", "log out to ask")
    key("Escape")
    wait(lambda: ui()["confirm"] == "", "cancel")
    spotlight("lo")
    wait(lambda: ui()["results"][:1] == ["Top Hit: Log Out"], "the last pick on top")
    shot("spotlight-top-hit")
    key("Return")
    wait(lambda: ui()["confirm"] == "Log Out", "Enter alone to pick it")
    key("Escape")
    wait(lambda: ui()["confirm"] == "", "cancel again")


@test
def spotlight_offers_app_actions():
    spotlight("notes")
    assert "Applications: Quiet Notes" in ui()["results"], ui()["results"]
    assert not any(r.startswith("Actions: ") for r in ui()["results"]), "the app alone lists no actions"
    spotlight("notes new")
    wait(lambda: ui()["results"][:1] == ["Actions: New Note"], "the app's own action")
    shot("spotlight-actions")
    key("Return")
    wait(lambda: ["nm-connection-editor", "new-note"] in fake()["log"], "the action to run")


@test
def clipboard_history_copies_an_entry():
    shell("clipboard")
    wait(lambda: ui()["spotlight"], "clipboard opens spotlight")
    wait(lambda: ui()["clipboard"], "clipboard mode, with no text typed for you")
    time.sleep(0.6)
    shot("spotlight-clipboard")
    typed("exam")
    time.sleep(0.3)
    key("Return")
    wait(lambda: fake().get("clipboard") == "https://example.com/page", "entry to copy")


@test
def notification_actions_reach_the_app():
    before = ui()["notices"]
    app = subprocess.Popen(["notify-send", "--app-name=Mail", "--action=reply=Reply", "--action=later=Later", "New message", "From a test"], env=env, stdout=subprocess.PIPE, text=True)
    try:
        wait(lambda: ui()["notices"] == before + 1, "notification")
        wait(lambda: ui()["banner"], "banner")
        time.sleep(0.4)
        shot("banner-actions")
        move(1730, 112)
        time.sleep(5.2)
        assert ui()["banner"], "banner left while hovered"
        click(1660, 112)
        assert app.wait(timeout=5) == 0
        assert app.stdout.read().strip() == "reply", "wrong action"
        wait(lambda: ui()["notices"] == before, "notice to clear")
    finally:
        app.kill()


@test
def notification_centre_groups_by_app():
    shell("close")
    for number in range(3):
        sh("notify-send", "--app-name=Builds", f"Build {number}", "Finished")
        time.sleep(0.1)
    shell("notifications")
    wait(lambda: ui()["panel"] == "notifications", "centre")
    time.sleep(0.5)
    shot("notifications-grouped")
    shell("close")


@test
def agenda_appears_in_the_centre():
    shell("notifications")
    wait(lambda: ui()["agenda"], "agenda", timeout=8)
    assert [e["title"] for e in ui()["agenda"]] == ["Conference", "Galois Theory"], ui()["agenda"]
    time.sleep(0.5)
    shot("agenda")
    shell("close")


@test
def dock_labels_and_right_click_menu():
    start = len(clients())
    reveal_dock()
    move(960, 1040)
    time.sleep(0.4)
    shot("dock-label")
    sh("wlrctl", "pointer", "click", "right")
    wait(lambda: ui()["panel"] == "dock", "menu")
    time.sleep(0.3)
    shot("dock-menu")
    click(960, 947)
    wait(lambda: len(clients()) == start + 1, "new window", timeout=8)
    time.sleep(0.5)
    reveal_dock()
    move(960, 1040)
    sh("wlrctl", "pointer", "click", "right")
    wait(lambda: ui()["panel"] == "dock", "menu again")
    time.sleep(0.3)
    click(960, 977)
    wait(lambda: not [c for c in clients() if c["class"] == "kitty"], "windows to close", timeout=8)
    for _ in range(2):
        sh("hyprctl", "dispatch", 'hl.dsp.exec_cmd("kitty -o confirm_os_window_close=0")')
        time.sleep(1.5)
    wait(lambda: len(clients()) >= 2, "windows back", timeout=8)


@test
def screenshot_tool_captures_and_confirms():
    before = ui()["notices"]
    shell("screenshot")
    wait(lambda: ui()["screenshot"], "tool")
    time.sleep(0.3)
    shot("screenshot-tool")
    click(841, 923)
    wait(lambda: not ui()["screenshot"], "tool to leave the picture")
    wait(lambda: ui()["notices"] == before + 1, "saved notice", timeout=6)
    assert [c for c in fake()["log"] if c[:2] == ["grim", "-g"]], "area not used"
    time.sleep(0.4)
    shot("screenshot-saved")
    set_fake(slurp_cancel=True)
    shell("screenshot")
    wait(lambda: ui()["screenshot"], "tool again")
    time.sleep(0.3)
    click(841, 923)
    time.sleep(1.2)
    set_fake(slurp_cancel=False)
    assert ui()["notices"] == before + 1, "cancelling must not report anything"


@test
def weather_appears_in_the_centre():
    set_fake(offline=False)
    shell("notifications")
    wait(lambda: ui()["weather"], "weather", timeout=8)
    weather = ui()["weather"]
    assert (weather["place"], weather["condition"], weather["temperature"]) == ("Warsaw", "Partly cloudy", "11°"), weather
    assert len(weather["hours"]) == 5 and weather["hours"][0]["condition"] == "Light rain", weather
    calls = [" ".join(c) for c in fake()["log"] if c[:1] == ["curl"]]
    assert calls and "52.25,21.0" in calls[-1], calls
    time.sleep(0.4)
    shot("weather")


@test
def shortcut_sheet_matches_real_binds():
    shell("shortcuts")
    wait(lambda: ui()["panel"] == "" and ui()["cheatSheet"], "sheet")
    time.sleep(0.3)
    shot("shortcuts")
    binds = json.loads(sh("hyprctl", "-j", "binds").stdout)
    real = {(b["modmask"], b["key"].lower()) for b in binds}
    masks = {"SUPER": 64, "SHIFT": 1, "CTRL": 4}
    for entry in ui()["shortcuts"]:
        *mods, name = entry.split(" + ")
        wanted = (sum(masks[m] for m in mods), name.lower())
        assert wanted in real, f"{entry} is not bound"
    key("Escape")
    wait(lambda: not ui()["cheatSheet"], "escape to close")


@test
def changing_desktop_shows_where_you_landed():
    start = json.loads(sh("hyprctl", "-j", "activeworkspace").stdout)["id"]
    sh("hyprctl", "dispatch", "hl.dsp.focus({workspace=6})")
    wait(lambda: ui()["deskHud"] == 6, "desktop indicator")
    time.sleep(0.3)
    shot("desk-hud")
    wait(lambda: ui()["deskHud"] == 0, "indicator to leave", timeout=3)
    sh("hyprctl", "dispatch", f"hl.dsp.focus({{workspace={start}}})")
    wait(lambda: ui()["deskHud"] == start, "indicator on return")


def restart_shell():
    path = os.environ.get("QUIET_SHELL_PATH", str(repo / "packages/quiet-shell/shell"))
    if env.get("QUIET_FAKE_STATE") != str(state_file):
        raise RuntimeError("Restart requires the private run's fake state file")
    terminate_shell(path, env)
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
    if only and not any(part in fn.__name__ for part in only.split("|")):
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
