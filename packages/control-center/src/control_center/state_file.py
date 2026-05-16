"""Cross-process single-instance lock and view-handoff JSON file."""

import fcntl
import json
import os

from .constants import LOCK_PATH, STATE_PATH

_lock_fd = None


def acquire_lock():
    global _lock_fd
    _lock_fd = open(LOCK_PATH, "w")
    fcntl.flock(_lock_fd, fcntl.LOCK_EX)


def release_lock():
    global _lock_fd
    if _lock_fd is not None:
        fcntl.flock(_lock_fd, fcntl.LOCK_UN)
        _lock_fd.close()
        _lock_fd = None


def read_state():
    try:
        with open(STATE_PATH) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def write_state(pid, view, visible):
    with open(STATE_PATH, "w") as f:
        json.dump({"pid": pid, "view": view, "visible": visible}, f)


def clear_state(expected_pid):
    state = read_state()
    if state.get("pid") == expected_pid:
        try:
            os.unlink(STATE_PATH)
        except OSError:
            pass


def process_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False
