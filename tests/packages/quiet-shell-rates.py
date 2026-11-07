"""Check rates.py fetches, keeps a copy, and falls back to it when offline."""

import json
import os
import pathlib
import subprocess
import sys
import tempfile

rates, fake = sys.argv[1:3]

with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    bin_dir = root / "bin"
    bin_dir.mkdir()
    curl = bin_dir / "curl"
    curl.write_text(f"#!{sys.executable}\n" + pathlib.Path(fake).read_text().split("\n", 1)[1])
    curl.chmod(0o755)
    fake_state = root / "fake.json"
    env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "QUIET_FAKE_STATE": str(fake_state), "XDG_STATE_HOME": str(root / "state")}

    def run():
        return subprocess.run([sys.executable, rates], env=env, capture_output=True, text=True, check=True).stdout

    def fetches():
        return sum(1 for c in json.loads(fake_state.read_text())["log"] if c[0] == "curl")

    fake_state.write_text(json.dumps({"rates": False}))
    assert run() == "", "nothing known and offline prints nothing"

    fake_state.write_text(json.dumps({"rates": True}))
    first = json.loads(run())
    assert first["date"] == "2026-11-06" and first["rates"]["EUR"] == 1 and first["rates"]["PLN"] == 4.3, first
    assert (root / "state/quiet-shell/rates.json").exists()

    before = fetches()
    assert json.loads(run()) == first
    assert fetches() == before, "a fresh copy isn't fetched again"

    # A stale copy is refetched, and still used when that fails.
    cache = root / "state/quiet-shell/rates.json"
    os.utime(cache, (0, 0))
    state = json.loads(fake_state.read_text())
    state["rates"] = False
    fake_state.write_text(json.dumps(state))
    assert json.loads(run()) == first
    assert fetches() == before + 1

print("quiet-shell rates: ok")
