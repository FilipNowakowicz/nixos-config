"""Screenshot storage follows XDG without recreating ~/Pictures."""

import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

script = sys.argv.pop(1)


class StorageTests(unittest.TestCase):
    def capture(self, configured, data_home=None):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            target = home / "custom photos" if configured == "custom" else home / ".local/share/pictures"
            if data_home:
                target = home / data_home / "pictures"

            def command(args, **kwargs):
                output = ""
                if args[0] == "xdg-user-dir":
                    output = str(target) if configured == "custom" else str(home) if configured == "disabled" else ""
                elif args[0] == "grim":
                    Path(args[-1]).write_bytes(b"test image")
                elif args[0] == "wl-copy":
                    self.assertEqual(kwargs["stdin"].read(), b"test image")
                else:
                    self.fail(f"Unexpected command: {args}")
                return subprocess.CompletedProcess(args, 0, stdout=output, stderr="")

            environment = {"HOME": str(home)}
            if data_home:
                environment["XDG_DATA_HOME"] = str(home / data_home)
            result = io.StringIO()
            with patch.dict(os.environ, environment, clear=True), patch.object(sys, "argv", [script, "screen"]), patch("subprocess.run", side_effect=command), contextlib.redirect_stdout(result):
                runpy.run_path(script, run_name="__main__")
            path = Path(json.loads(result.getvalue())["path"])
            self.assertEqual(path.parent, target / "Screenshots")
            self.assertTrue(path.is_file())
            self.assertFalse((home / "Pictures").exists())

    def test_configured_pictures(self):
        self.capture("custom")

    def test_disabled_pictures(self):
        self.capture("disabled")

    def test_missing_pictures(self):
        self.capture("missing")

    def test_custom_data_home(self):
        self.capture("missing", "data")


unittest.main()
