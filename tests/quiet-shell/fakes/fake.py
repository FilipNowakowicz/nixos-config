#!/usr/bin/env python3
"""One stateful fake for every system command the shell calls.

Symlink this under each command's name. State lives in $QUIET_FAKE_STATE as JSON.
A key `fail` listing command names makes those exit 1 without changing state, and
`stick` makes them exit 0 without changing state, so readback must catch it.
"""

import json
import os
import pathlib
import sys

state_path = pathlib.Path(os.environ["QUIET_FAKE_STATE"])
DEFAULT = {
    "wifi": True, "ssid": "Harbour 5G",
    "networks": [["Harbour 5G", 92, "WPA2"], ["Harbour 2.4G", 70, "WPA2"], ["Kavarna Guest", 31, "WPA2"], ["Open Cafe", 28, ""], ["Campus", 25, "WPA2 802.1X"]],
    "known": ["Harbour 5G", "Harbour 2.4G"], "wifi_password": "correct horse",
    "nearby": {"AA:BB:CC:00:00:03": "Speaker", "AA:BB:CC:00:00:04": "AA-BB-CC-00-00-04"},
    "bt": True,
    "devices": {"AA:BB:CC:00:00:01": ["Headphones", True], "AA:BB:CC:00:00:02": ["Trackball", False]},
    "tailscale": True, "mullvad": False,
    "volume": 0.59, "muted": False, "mic": 0.5, "mic_muted": False,
    "sink": "alsa_output.speakers", "source": "alsa_input.internal",
    "brightness": 50, "profile": "balanced", "night": False, "awake": False,
    "playing": True, "fail": [], "stick": [], "log": [],
}
state = {**DEFAULT, **(json.loads(state_path.read_text()) if state_path.exists() else {})}
cmd, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
state["log"].append([cmd, *args])


def done(code=0):
    state_path.write_text(json.dumps(state))
    sys.exit(code)


READS = (("nmcli", "radio", "wifi"), ("nmcli", "-t"))
is_read = args[:1] in (["-t"], ["show"], ["devices"], ["status"], ["get-volume"], ["get"], ["metadata"], ["-m"]) or cmd in ("pw-dump", "pgrep") or args == ["radio", "wifi"] or args[:1] == ["--user"] and "is-active" in args
if not is_read:
    if cmd in state["fail"]:
        done(1)
    if cmd in state["stick"]:
        done(0)

if cmd == "nmcli":
    if args == ["radio", "wifi"]:
        print("enabled" if state["wifi"] else "disabled")
    elif args[:2] == ["radio", "wifi"]:
        state["wifi"] = args[2] == "on"
    elif args[0] == "-t" and "connection" in args:
        for name in state["known"]:
            print(f"{name}:802-11-wireless")
        print("Wired:802-3-ethernet")
    elif args[0] == "-t":
        for name, signal, security in state["networks"] if state["wifi"] else []:
            print(f"{'yes' if name == state['ssid'] else 'no'}:{name}:{signal}:{security}")
    elif args[:3] == ["dev", "wifi", "connect"]:
        state["ssid"] = args[3]
    elif args[:4] == ["--ask", "dev", "wifi", "connect"]:
        # Like nmcli, the profile exists even when the password turns out wrong.
        state["known"].append(args[4])
        if sys.stdin.readline().rstrip("\n") != state["wifi_password"]:
            done(4)
        state["ssid"] = args[4]
    elif args[:3] == ["connection", "delete", "id"]:
        state["known"].remove(args[3])
elif cmd == "bluetoothctl":
    if args == ["show"]:
        print(f"Powered: {'yes' if state['bt'] else 'no'}")
    elif args == ["devices", "Paired"]:
        for addr, (name, _) in state["devices"].items():
            print(f"Device {addr} {name}")
    elif args == ["devices"]:
        for addr, (name, _) in state["devices"].items():
            print(f"Device {addr} {name}")
        for addr, name in state["nearby"].items():
            print(f"Device {addr} {name}")
    elif args[:2] == ["--agent", "NoInputNoOutput"] and args[2] == "pair":
        state["devices"][args[3]] = [state["nearby"].pop(args[3]), False]
    elif args == ["devices", "Connected"]:
        for addr, (name, on) in state["devices"].items():
            if on:
                print(f"Device {addr} {name}")
    elif args[0] == "power":
        state["bt"] = args[1] == "on"
    elif args[0] in ("connect", "disconnect"):
        state["devices"][args[1]][1] = args[0] == "connect"
elif cmd == "tailscale":
    if args[0] == "status":
        print(json.dumps({"BackendState": "Running" if state["tailscale"] else "Stopped"}))
    else:
        state["tailscale"] = args[0] == "up"
elif cmd == "mullvad":
    if args[0] == "status":
        print("Connected to Stockholm" if state["mullvad"] else "Disconnected")
    else:
        state["mullvad"] = args[0] == "connect"
elif cmd == "wpctl":
    source = "SOURCE" in (args[1] if len(args) > 1 else "")
    key, mute = ("mic", "mic_muted") if source else ("volume", "muted")
    if args[0] == "get-volume":
        print(f"Volume: {state[key]:.2f}{' [MUTED]' if state[mute] else ''}")
    elif args[0] == "set-volume":
        state[key] = float(args[2])
    elif args[0] == "set-mute":
        state[mute] = args[2] == "1"
elif cmd == "pw-dump":
    def node(name, desc, cls):
        return {"type": "PipeWire:Interface:Node", "info": {"props": {"node.name": name, "node.description": "Sound Card " + desc, "node.nick": desc, "media.class": cls}}}
    print(json.dumps([
        {"type": "PipeWire:Interface:Metadata", "props": {"metadata.name": "default"}, "metadata": [
            {"subject": 0, "key": "default.audio.sink", "value": {"name": state["sink"]}},
            {"subject": 0, "key": "default.audio.source", "value": {"name": state["source"]}}]},
        node("alsa_output.speakers", "Laptop speakers", "Audio/Sink"),
        node("bluez_output.headphones", "Headphones", "Audio/Sink"),
        node("alsa_input.internal", "Internal microphone", "Audio/Source"),
        node("alsa_input.usb", "USB microphone", "Audio/Source"),
    ]))
elif cmd == "pw-metadata":
    role = "sink" if args[3].endswith("sink") else "source"
    state[role] = json.loads(args[4])["name"]
elif cmd == "brightnessctl":
    if args[0] == "-m":
        print(f"intel_backlight,backlight,{state['brightness']},{state['brightness']}%,100")
    else:
        state["brightness"] = int(args[1].rstrip("%"))
elif cmd == "powerprofilesctl":
    if args[0] == "get":
        print(state["profile"])
    else:
        state["profile"] = args[1]
elif cmd == "playerctl":
    if args[0] == "metadata":
        print(f"{'Playing' if state['playing'] else 'Paused'}\tBlue in Green\tMiles Davis\t")
    elif args[0] == "play-pause":
        state["playing"] = not state["playing"]
elif cmd == "pgrep":
    done(0 if state["night"] else 1)
elif cmd == "pkill":
    state["night"] = False
elif cmd == "setsid":
    state["night"] = True
elif cmd == "systemctl":
    if "is-active" in args:
        done(0 if state["awake"] else 3)
    if "stop" in args:
        state["awake"] = False
elif cmd == "systemd-run":
    state["awake"] = True
elif cmd == "theme-switch":
    colors = pathlib.Path(os.environ["QUIET_COLORS"])
    data = json.loads(colors.read_text())
    data.update({"name": args[0], "accent": "8aa4b8", "bg": "161a20", "text": "c8d0d8"})
    colors.write_text(json.dumps(data))
done()
