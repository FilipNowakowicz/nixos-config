"""Check phone.py against a fake busctl standing in for KDE Connect's daemon."""

import json
import os
import pathlib
import subprocess
import sys
import tempfile

script = sys.argv[1]
DEV = "/modules/kdeconnect/devices"


def typed(value):
    kind = {bool: "b", int: "i", str: "s"}.get(type(value), "as")
    return {"type": kind, "data": value}


def props(**values):
    return {"type": "a{sv}", "data": [{k: typed(v) for k, v in values.items()}]}


def run(answers):
    """phone.py with busctl answering from `answers`, keyed by path and method."""
    with tempfile.TemporaryDirectory() as tmp:
        bin_ = pathlib.Path(tmp)
        (bin_ / "answers.json").write_text(json.dumps(answers))
        fake = bin_ / "busctl"
        fake.write_text(f"""#!{sys.executable}
import json, sys
args = sys.argv[1:]
# busctl --user -j call SERVICE PATH INTERFACE METHOD [SIGNATURE ARGS...]
path, interface, method = args[4], args[5], args[6]
key = path + " " + (args[8] if method == "GetAll" else method)
answers = json.load(open({str(bin_ / "answers.json")!r}))
if key not in answers:
    sys.exit(1)
print(json.dumps(answers[key]))
""")
        fake.chmod(0o755)
        env = {"PATH": f"{bin_}:{os.environ.get('PATH', '')}"}
        out = subprocess.run([sys.executable, script], env=env, capture_output=True, text=True, check=True)
        return json.loads(out.stdout)


# No daemon: nothing paired, nothing to show.
assert run({}) == {"phones": []}

phone = f"{DEV}/p1"
tablet = f"{DEV}/t1"
answers = {
    "/modules/kdeconnect devices": {"type": "as", "data": [["t1", "p1", "gone"]]},
    f"{phone} org.kde.kdeconnect.device": props(name="Galaxy", type="phone", isReachable=True),
    f"{phone}/battery org.kde.kdeconnect.device.battery": props(hasBattery=True, charge=42, isCharging=False),
    f"{phone}/connectivity_report org.kde.kdeconnect.device.connectivity_report": props(cellularNetworkStrength=3, cellularNetworkType="5G"),
    f"{phone}/notifications activeNotifications": {"type": "as", "data": [["1", "2", "3", "4", "5", "6"]]},
    # Paired but out of reach: only its name is worth asking for.
    f"{tablet} org.kde.kdeconnect.device": props(name="Tab", type="tablet", isReachable=False),
}
for n in range(1, 7):
    answers[f"{phone}/notifications/{n} org.kde.kdeconnect.device.notifications.notification"] = props(
        appName="Messages", title=f"Ana {n}", text="see you", replyId="r" if n == 6 else "", silent=n == 1)
# Notification 3 vanished between the list and the read.
del answers[f"{phone}/notifications/3 org.kde.kdeconnect.device.notifications.notification"]

got = run(answers)["phones"]
assert [p["name"] for p in got] == ["Galaxy", "Tab"], got
galaxy, tab = got
assert galaxy["battery"] == {"charge": 42, "charging": False}, galaxy
assert galaxy["signal"] == {"strength": 3, "type": "5G"}, galaxy
# Newest first, four shown and the rest counted; a silent one still counts.
assert [n["title"] for n in galaxy["notifications"]] == ["Ana 6", "Ana 5", "Ana 4", "Ana 2"], galaxy
assert galaxy["more"] == 1, galaxy
assert galaxy["notifications"][0]["reply"] and not galaxy["notifications"][1]["reply"], galaxy
assert tab == {"id": "t1", "name": "Tab", "type": "tablet", "reachable": False, "battery": None,
               "signal": None, "notifications": [], "more": 0}, tab

print("quiet-shell phone.py: ok")
