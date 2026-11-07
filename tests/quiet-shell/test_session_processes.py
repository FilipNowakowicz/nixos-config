"""Restart selection must never cross private desktop boundaries."""

import ast
import os
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from session_processes import terminate_shell


class RestartTests(unittest.TestCase):
    def setUp(self):
        self.children = []
        self.path = "/same/store/path/quiet-shell"
        self.env = {
            "XDG_RUNTIME_DIR": "/private/runtime",
            "HYPRLAND_INSTANCE_SIGNATURE": "private-compositor",
            "QUIET_FAKE_STATE": "/private/run/state.json",
        }

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=5)

    def child(self, overrides=None, args=None):
        env = dict(os.environ, **self.env)
        env["PYTHONHOME"] = sys.prefix
        env.update(overrides or {})
        child = subprocess.Popen(
            ["quickshell", "-c", "import time; time.sleep(60)", *(args or ["-p", self.path])],
            executable=sys.executable,
            env=env,
        )
        self.children.append(child)
        return child

    def test_only_exact_private_shell_is_terminated(self):
        private = self.child()
        others = [
            self.child({"XDG_RUNTIME_DIR": "/live/runtime"}),
            self.child({"HYPRLAND_INSTANCE_SIGNATURE": "live-compositor"}),
            self.child({"QUIET_FAKE_STATE": ""}),
            self.child(args=["-p", self.path + "-other"]),
            self.child(args=["ipc", "-p", self.path]),
            self.child(args=["--unrelated", self.path]),
        ]
        self.assertEqual(terminate_shell(self.path, self.env), private.pid)
        self.assertEqual(private.wait(timeout=5), -15)
        self.assertTrue(all(child.poll() is None for child in others))

    def test_missing_session_identity_fails_closed(self):
        private = self.child()
        for key in self.env:
            with self.subTest(key=key), self.assertRaises(ValueError):
                terminate_shell(self.path, {**self.env, key: ""})
        self.assertIsNone(private.poll())

    def test_unreadable_identity_is_not_selected(self):
        private = self.child()
        original_read = Path.read_bytes

        def read(path):
            if path.name == "environ":
                raise PermissionError("Cannot observe process identity")
            return original_read(path)

        with patch.object(Path, "read_bytes", read), self.assertRaises(RuntimeError):
            terminate_shell(self.path, self.env)
        self.assertIsNone(private.poll())

    def test_ambiguous_target_fails_without_signalling(self):
        first, second = self.child(), self.child()
        with self.assertRaises(RuntimeError):
            terminate_shell(self.path, self.env)
        self.assertIsNone(first.poll())
        self.assertIsNone(second.poll())

    def test_acceptance_restart_uses_private_run_identity(self):
        private = self.child()
        live = self.child({"HYPRLAND_INSTANCE_SIGNATURE": "live-compositor"})
        # Load just the runner's restart entrypoint without starting GUI tests.
        source = Path(__file__).with_name("acceptance.py")
        tree = ast.parse(source.read_text())
        restart = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "restart_shell")
        scope = {
            "os": SimpleNamespace(environ={"QUIET_SHELL_PATH": self.path}),
            "repo": Path("/repo"),
            "env": self.env,
            "state_file": Path(self.env["QUIET_FAKE_STATE"]),
            "terminate_shell": terminate_shell,
            "time": SimpleNamespace(sleep=lambda _: None),
            "ui": lambda: True,
            "wait": lambda check, *args, **kwargs: self.assertTrue(check()),
        }
        exec(compile(ast.Module(body=[restart], type_ignores=[]), str(source), "exec"), scope)
        scope["restart_shell"]()
        self.assertEqual(private.wait(timeout=5), -15)
        self.assertIsNone(live.poll())


if __name__ == "__main__":
    unittest.main()
