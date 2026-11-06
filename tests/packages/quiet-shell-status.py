"""Check status.py against faked commands, and with no commands at all."""

import json
import os
import pathlib
import subprocess
import sys
import tempfile

status, fake = sys.argv[1:3]
COMMANDS = "nmcli bluetoothctl tailscale mullvad wpctl pw-dump brightnessctl powerprofilesctl playerctl pgrep systemctl".split()

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
    assert len(out["wifi"]["networks"]) == 3
    assert out["bluetooth"]["on"] and out["bluetooth"]["devices"][0]["connected"], out["bluetooth"]
    assert out["vpn"] == {"tailscale": True, "mullvad": False}, out["vpn"]
    assert out["sink"] == {"level": 59, "muted": False}, out["sink"]
    assert [d["name"] for d in out["devices"]["sinks"] if d["active"]] == ["alsa_output.speakers"]
    assert out["brightness"] == 50 and out["profile"] == "balanced"
    assert out["battery"] == {"level": 64, "charging": True}, out["battery"]
    assert out["media"]["title"] == "Blue in Green"

    empty = json.loads(subprocess.check_output(
        [sys.executable, status], env={"PATH": str(root / "nothing"), "QUIET_POWER_SUPPLY": str(root / "none")}))
    for key in ("wifi", "bluetooth", "vpn", "sink", "devices", "brightness", "profile", "battery", "media"):
        assert empty[key] is None, (key, empty[key])
print("quiet-shell status: ok")
