"""Check status.py against faked commands, and with no commands at all."""

import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile

status, fake, location, buds_script, agenda = sys.argv[1:6]
COMMANDS = "nmcli bluetoothctl tailscale mullvad wpctl pw-dump brightnessctl powerprofilesctl playerctl pgrep systemctl khal".split()

with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    bin_dir = root / "bin"
    bin_dir.mkdir()
    # Each fake learns its name from argv[0], so copy it rather than wrap it.
    source = pathlib.Path(fake).read_text().split("\n", 1)[1]
    for name in COMMANDS:
        link = bin_dir / name
        link.write_text(f"#!{sys.executable}\n{source}")
        link.chmod(0o755)
    power = root / "power/BAT0"
    power.mkdir(parents=True)
    (power / "capacity").write_text("64\n")
    (power / "status").write_text("Charging\n")
    env = {
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "QUIET_FAKE_STATE": str(root / "state.json"),
        "QUIET_POWER_SUPPLY": str(root / "power"),
    }
    out = json.loads(subprocess.check_output([sys.executable, status], env=env))
    assert out["wifi"]["on"] is True and out["wifi"]["ssid"] == "Harbour 5G", out["wifi"]
    # The access point in use is rarely the strongest one with that name.
    assert len(out["wifi"]["networks"]) == 5
    assert out["wifi"]["networks"][0] == {"name": "Harbour 5G", "active": True, "signal": 96, "security": "WPA2", "known": True}, out["wifi"]
    guest = next(n for n in out["wifi"]["networks"] if n["name"] == "Kavarna Guest")
    assert guest["security"] == "WPA2" and not guest["known"], guest
    assert next(n for n in out["wifi"]["networks"] if n["name"] == "Harbour 2.4G")["known"]
    # Unnamed devices, low-energy twins and paired devices never count as nearby.
    assert out["bluetooth"]["nearby"] == [{"addr": "AA:BB:CC:00:00:03", "name": "Speaker"}], out["bluetooth"]
    assert out["devices"]["sources"][0]["desc"] == "Internal microphone", out["devices"]
    assert out["bluetooth"]["on"] and out["bluetooth"]["devices"][0]["connected"], out["bluetooth"]
    assert out["vpn"]["tailscale"] and not out["vpn"]["mullvad"], out["vpn"]
    assert out["vpn"]["country"] == "se" and out["vpn"]["exitNodes"] == ["home-box", "relay-box"], out["vpn"]
    countries = json.loads(subprocess.check_output([sys.executable, status, "countries"], env=env))
    assert {"name": "UK", "code": "gb"} in countries and len(countries) == 3, countries
    assert out["sink"] == {"level": 59, "muted": False}, out["sink"]
    assert [d["name"] for d in out["devices"]["sinks"] if d["active"]] == ["alsa_output.speakers"]
    assert out["brightness"] == 50 and out["profile"] == "balanced"
    assert out["battery"] == {"level": 64, "charging": True}, out["battery"]
    assert out["media"]["title"] == "Blue in Green"

    empty = json.loads(subprocess.check_output(
        [sys.executable, status], env={"PATH": str(root / "nothing"), "QUIET_POWER_SUPPLY": str(root / "none")}))
    for key in ("wifi", "bluetooth", "vpn", "sink", "devices", "brightness", "profile", "battery", "media"):
        assert empty[key] is None, (key, empty[key])

    # An event khal repeats on each day it covers is one event. No khal, no agenda.
    listed = json.loads(subprocess.check_output([sys.executable, agenda], env=env))
    assert [e["title"] for e in listed] == ["Conference", "Galois Theory"], listed
    assert listed[0]["day"] < listed[0]["until"] and listed[0]["start"] == "", listed
    assert listed[1]["start"] == "11:00" and listed[1]["location"] == "HXLY 342", listed
    assert subprocess.check_output([sys.executable, agenda], env={"PATH": str(root / "nothing")}) == b""
print("quiet-shell status: ok")

# A real status message from Buds4 Pro, with the left bud away. Frames are the only
# thing standing between a typo and sending the wrong command to real hardware.
spec = importlib.util.spec_from_file_location("buds", buds_script)
buds = importlib.util.module_from_spec(spec)
spec.loader.exec_module(buds)
captured = bytes.fromhex(
    "fd410061040d0063000001000000ff2200006701670102000499000404100000010011020000"
    "00000000000100000000000000010201000100010104000000000001d3dcdd"
)
found, rest = buds.frames(captured + captured[:5])
assert len(found) == 1 and found[0][0] == buds.STATUS and rest == captured[:5], (found, rest)
assert buds.status(found[0][1]) == {"left": None, "right": 99, "case": None, "mode": "off"}, buds.status(found[0][1])
corrupt = bytearray(captured)
corrupt[8] ^= 1
assert buds.frames(bytes(corrupt))[0] == [], "a bad checksum must never be trusted"
sent = buds.frame(buds.SET_NOISE_CONTROL, bytes([buds.MODES["anc"]]))
assert buds.frames(sent)[0] == [(0x78, b"\x01")], sent.hex()
print("quiet-shell buds: ok")

with tempfile.TemporaryDirectory() as tmp:
    table = pathlib.Path(tmp) / "zone1970.tab"
    table.write_text(
        "# comment\n"
        "GB,GG,IM,JE\t+513030-0000731\tEurope/London\n"
        "PL\t+5215+02100\tEurope/Warsaw\n"
        "US\t+611305-1495401\tAmerica/Anchorage\n"
        "NZ\t-3652+17446\tPacific/Auckland\n"
    )

    def where(zone):
        env = {"QUIET_ZONE_TAB": str(table), "QUIET_TIMEZONE": zone}
        return subprocess.run([sys.executable, location], env=env, capture_output=True, text=True, check=False)

    assert where("Europe/London").stdout.split() == ["-l", "51.51", "-L", "-0.13"], where("Europe/London")
    assert where("Europe/Warsaw").stdout.split() == ["-l", "52.25", "-L", "21.0"]
    assert where("America/Anchorage").stdout.split() == ["-l", "61.22", "-L", "-149.9"]
    assert where("Pacific/Auckland").stdout.split() == ["-l", "-36.87", "-L", "174.77"]
    assert where("Mars/Base").returncode != 0, "an unknown zone must not pick a location"
