"""Setting write races, actual command results and fresh read-back requirements."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import threading
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("settings", Path(sys.argv.pop(1)))
settings = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = settings
spec.loader.exec_module(settings)


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.now = 10
        self.model = settings.Settings(lambda: self.now)

    def test_success_requires_fresh_readback(self):
        token = self.model.begin("wifi.enabled", False, "Wi-Fi")
        self.assertFalse(self.model.effective("wifi.enabled", True, 9))
        self.model.complete("wifi.enabled", token, "ok", 11)
        self.assertFalse(self.model.effective("wifi.enabled", False, 10))
        self.assertEqual(self.model.requests["wifi.enabled"].phase, "confirming")
        self.model.effective("wifi.enabled", False, 12)
        self.assertEqual(self.model.requests["wifi.enabled"].phase, "confirmed")

    def test_latest_intent_rejects_stale_completion_and_old_matching_poll(self):
        old = self.model.begin("wifi.enabled", False, "Wi-Fi")
        new = self.model.begin("wifi.enabled", True, "Wi-Fi")
        self.assertFalse(self.model.complete("wifi.enabled", old, "failed", 11))
        self.model.effective("wifi.enabled", True, 12)
        self.assertEqual(self.model.requests["wifi.enabled"].phase, "writing")
        self.model.complete("wifi.enabled", new, "ok", 13)
        self.model.effective("wifi.enabled", True, 12)
        self.assertEqual(self.model.requests["wifi.enabled"].phase, "confirming")

    def test_failure_reverts_visual_value_and_remains_retryable(self):
        token = self.model.begin("wifi.enabled", False, "Wi-Fi")
        self.model.complete("wifi.enabled", token, "failed", 11)
        self.assertTrue(self.model.effective("wifi.enabled", True, 12))
        self.assertEqual(self.model.latest()[1].phase, "failed")
        retry = self.model.begin("wifi.enabled", False, "Wi-Fi")
        self.assertGreater(retry, token)

    def test_timeout_is_unknown_and_can_reconcile_without_retry(self):
        token = self.model.begin("wifi.enabled", False, "Wi-Fi")
        self.model.complete("wifi.enabled", token, "unknown", 11)
        self.model.effective("wifi.enabled", True, 12)
        self.assertEqual(self.model.latest()[1].phase, "unknown")
        self.model.effective("wifi.enabled", False, 13)
        self.assertEqual(self.model.latest()[1].phase, "confirmed")

    def test_missing_confirmation_does_not_silently_look_successful(self):
        token = self.model.begin("wifi.enabled", False, "Wi-Fi")
        self.model.complete("wifi.enabled", token, "ok", 11)
        self.now = 21
        self.assertTrue(self.model.effective("wifi.enabled", True, 20))
        self.assertEqual(self.model.latest()[1].phase, "unknown")

    def test_ordered_worker_coalesces_queued_writes(self):
        started, release, finished = (threading.Event() for _ in range(3))
        seen, completed = [], []

        def run(command):
            seen.append(command)
            if command == ["first"]:
                started.set()
                self.assertTrue(release.wait(3))
            return "ok"

        def done(key, token, outcome, timestamp):
            completed.append(token)
            if token == 3:
                finished.set()

        writer = settings.OrderedWriter(run)
        writer.submit("wifi", 1, ["first"], done)
        self.assertTrue(started.wait(3))
        writer.submit("wifi", 2, ["superseded"], done)
        writer.submit("wifi", 3, ["latest"], done)
        release.set()
        self.assertTrue(finished.wait(3))
        self.assertEqual(seen, [["first"], ["latest"]])
        self.assertEqual(completed, [1, 3])

    def test_command_errors_and_no_implicit_retry(self):
        for error, outcome in ((FileNotFoundError(), "failed"),
                               (subprocess.TimeoutExpired("test", 8), "unknown")):
            with patch.object(settings.subprocess, "run", side_effect=error) as run:
                self.assertEqual(settings.run_command(["test"]), outcome)
                self.assertEqual(run.call_count, 1)

    def test_dnd_command_preserves_other_modes(self):
        self.assertEqual(settings.command_for("dnd.enabled", False),
                         ["makoctl", "mode", "-r", "do-not-disturb"])

    def test_bluetooth_device_identity_and_fresh_connection_readback(self):
        key = "bluetooth.device.00:11:22:33:44:55"
        self.assertEqual(settings.command_for(key, True), ["bluetoothctl", "connect", "00:11:22:33:44:55"])
        self.assertEqual(settings.command_for(key, False), ["bluetoothctl", "disconnect", "00:11:22:33:44:55"])
        for invalid in ("--help", "00:11:22:33:44:55;other", "00:11:22:33:44"):
            with self.assertRaises(ValueError):
                settings.command_for("bluetooth.device." + invalid, True)
        token = self.model.begin(key, True, "Bluetooth connection")
        self.model.complete(key, token, "ok", 11)
        self.model.effective(key, True, 10)
        self.assertEqual(self.model.requests[key].phase, "confirming")
        self.model.effective(key, True, 12)
        self.assertEqual(self.model.requests[key].phase, "confirmed")

    def test_real_process_exit_codes(self):
        self.assertEqual(settings.run_command([sys.executable, "-c", "pass"]), "ok")
        self.assertEqual(settings.run_command([sys.executable, "-c", "raise SystemExit(1)"]), "failed")

    def test_unresolved_setting_survives_another_settings_success(self):
        wifi = self.model.begin("wifi.enabled", False, "Wi-Fi")
        self.model.complete("wifi.enabled", wifi, "failed", 11)
        dnd = self.model.begin("dnd.enabled", True, "Do Not Disturb")
        self.model.complete("dnd.enabled", dnd, "ok", 12)
        self.model.effective("dnd.enabled", True, 13)
        self.now = 20
        self.assertEqual(self.model.latest()[0], "wifi.enabled")

    def test_numeric_confirmation_allows_hardware_rounding(self):
        token = self.model.begin("brightness.percent", 37, "Brightness")
        self.model.complete("brightness.percent", token, "ok", 11)
        self.model.effective("brightness.percent", 38, 12)
        self.assertEqual(self.model.latest()[1].phase, "confirmed")

    def test_numeric_confirmation_rejects_wrong_level(self):
        token = self.model.begin("audio.sink_volume_pct", 37, "Volume")
        self.model.complete("audio.sink_volume_pct", token, "ok", 11)
        self.model.effective("audio.sink_volume_pct", 70, 12)
        self.assertEqual(self.model.latest()[1].phase, "confirming")

    def test_audio_device_uses_json_name_and_effective_fresh_readback(self):
        name = 'headphones "quoted" $(literal)'
        command = settings.command_for("audio.default_sink", name)
        self.assertEqual(command[:5], ["pw-metadata", "-n", "default", "0", "default.configured.audio.sink"])
        self.assertEqual(json.loads(command[5]), {"name": name})
        for invalid in (None, "", "bad\nname", "x" * 1025):
            with self.assertRaises(ValueError):
                settings.command_for("audio.default_sink", invalid)
        token = self.model.begin("audio.default_sink", name, "Output device")
        self.model.complete("audio.default_sink", token, "ok", 11)
        self.model.effective("audio.default_sink", name, 10)
        self.assertEqual(self.model.latest()[1].phase, "confirming")
        self.model.effective("audio.default_sink", None, 12)
        self.assertEqual(self.model.latest()[1].phase, "confirming")
        self.model.effective("audio.default_sink", name, 13)
        self.assertEqual(self.model.latest()[1].phase, "confirmed")

    def test_mute_is_idempotent_and_levels_are_explicit(self):
        self.assertEqual(settings.command_for("audio.sink_muted", True),
                         ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "1"])
        self.assertEqual(settings.command_for("audio.sink_volume_pct", 37),
                         ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.37"])
        with self.assertRaises(ValueError):
            settings.command_for("brightness.percent", 0)


unittest.main()
