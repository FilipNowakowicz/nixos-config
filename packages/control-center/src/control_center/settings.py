"""Tracked, ordered setting writes. No GTK dependency; callbacks choose their thread."""

from dataclasses import dataclass
import json
import subprocess
import threading
import time


def command_for(key, target):
    if key in ("audio.default_sink", "audio.default_source"):
        if not isinstance(target, str) or not target or len(target) > 1024 or any(ord(c) < 32 for c in target):
            raise ValueError("Invalid audio node name")
        role = key.removeprefix("audio.default_")
        return ["pw-metadata", "-n", "default", "0", f"default.configured.audio.{role}",
                json.dumps({"name": target}), "Spa:String:JSON"]
    if key == "wifi.enabled":
        return ["nmcli", "radio", "wifi", "on" if target else "off"]
    if key == "bluetooth.powered":
        return ["bluetoothctl", "power", "on" if target else "off"]
    if key == "dnd.enabled":
        return ["makoctl", "mode", "-a" if target else "-r", "do-not-disturb"]
    if key == "tailscale.enabled":
        return ["tailscale", "up" if target else "down"]
    if key == "mullvad.connected":
        return ["mullvad", "connect" if target else "disconnect"]
    if key == "power_profile" and target in ("power-saver", "balanced", "performance"):
        return ["powerprofilesctl", "set", target]
    if key in ("audio.sink_muted", "audio.source_muted"):
        device = "@DEFAULT_AUDIO_SINK@" if key == "audio.sink_muted" else "@DEFAULT_AUDIO_SOURCE@"
        return ["wpctl", "set-mute", device, "1" if target else "0"]
    if key in ("audio.sink_volume_pct", "audio.source_volume_pct") and 0 <= target <= 100:
        device = "@DEFAULT_AUDIO_SINK@" if key == "audio.sink_volume_pct" else "@DEFAULT_AUDIO_SOURCE@"
        return ["wpctl", "set-volume", device, f"{int(target) / 100:.2f}"]
    if key == "brightness.percent" and 1 <= target <= 100:
        return ["brightnessctl", "set", f"{int(target)}%"]
    raise ValueError(f"Unsupported setting: {key}")


def run_command(command):
    if command[:4] == ["pw-metadata", "-n", "default", "0"]:
        from .audio import write_default
        return write_default(command)
    try:
        result = subprocess.run(command, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=8, check=False)
        return "ok" if result.returncode == 0 else "failed"
    except subprocess.TimeoutExpired:
        return "unknown"
    except OSError:
        return "failed"


class OrderedWriter:
    """Serialize each setting; coalesce queued requests to the latest intent.

    Different settings may run concurrently. A running command is never retried
    automatically: after a timeout its effect is uncertain and must be read back.
    """

    def __init__(self, run=run_command):
        self.run = run
        self._lock = threading.Lock()
        self._jobs = {}
        self._running = set()

    def submit(self, key, token, command, done):
        with self._lock:
            self._jobs[key] = (token, command, done)
            if key in self._running:
                return
            self._running.add(key)
        threading.Thread(target=self._work, args=(key,), daemon=True).start()

    def _work(self, key):
        while True:
            with self._lock:
                job = self._jobs.pop(key, None)
                if job is None:
                    self._running.remove(key)
                    return
            token, command, done = job
            try:
                outcome = self.run(command)
            except Exception:
                outcome = "unknown"
            done(key, token, outcome, time.monotonic())


@dataclass
class Request:
    token: int
    target: object
    label: str
    phase: str = "writing"
    completed_at: float = float("inf")
    deadline: float = float("inf")


class Settings:
    """Main-thread model. Confirmation needs a poll started after completion."""

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.requests = {}
        self._token = 0

    def begin(self, key, target, label):
        self._token += 1
        request = Request(self._token, target, label, deadline=self.clock() + 30)
        self.requests[key] = request
        return request.token

    def complete(self, key, token, outcome, completed_at):
        request = self.requests.get(key)
        if request is None or request.token != token:
            return False
        request.completed_at = completed_at
        request.deadline = completed_at + 8
        request.phase = {"ok": "confirming", "failed": "failed"}.get(outcome, "unknown")
        return True

    def effective(self, key, polled, observed_at):
        request = self.requests.get(key)
        if request is None:
            return polled
        if request.phase in ("writing", "confirming") and self.clock() > request.deadline:
            request.phase = "unknown"
        if request.phase in ("confirming", "unknown"):
            matches = polled == request.target
            if key.endswith(("_volume_pct", ".percent")):
                # Hardware volume/backlight steps may round a percentage.
                matches = isinstance(polled, (int, float)) and abs(polled - request.target) <= 1
            if observed_at > request.completed_at and matches:
                request.phase = "confirmed"
                request.deadline = self.clock() + 2
        if request.phase in ("writing", "confirming"):
            return request.target
        return polled

    def latest(self):
        candidates = [(key, request) for key, request in self.requests.items()
                      if request.phase != "confirmed" or self.clock() <= request.deadline]
        if not candidates:
            return None
        return max(candidates, key=lambda item: item[1].token)
