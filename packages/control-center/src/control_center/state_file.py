"""Cross-process single-instance lock and view-handoff JSON file."""

import fcntl
import json
import os
import signal
from pathlib import Path

from .constants import LOCK_PATH, STATE_PATH

_lock_fd = None


def acquire_lock():
    global _lock_fd
    LOCK_PATH.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
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
            state = json.load(f)
            return state if isinstance(state, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def write_state(pid, view, visible, start_time=None):
    with open(STATE_PATH, "w") as f:
        json.dump({"pid": pid, "start_time": start_time if start_time is not None else process_start_time(pid), "view": view, "visible": visible}, f)


def clear_state(expected_pid):
    state = read_state()
    if state.get("pid") == expected_pid:
        try:
            os.unlink(STATE_PATH)
        except OSError:
            pass


def process_start_time(pid):
    try:
        # comm can contain spaces and parentheses; fields after its last ')' start at 3.
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return None


def process_alive(pid, start_time):
    return (isinstance(pid, int) and pid > 0 and start_time is not None
            and process_start_time(pid) == start_time)


def signal_instance(state, sig):
    """Pin the process before checking identity so PID reuse cannot redirect signals."""
    pid = state.get("pid")
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        fd = os.pidfd_open(pid)
        try:
            if not process_alive(pid, state.get("start_time")):
                return False
            signal.pidfd_send_signal(fd, sig)
            return True
        finally:
            os.close(fd)
    except (OSError, AttributeError):
        return False
