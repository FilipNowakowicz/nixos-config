"""Entry point: parse argv, take the single-instance lock, hand off to GTK."""

import os
import signal
import sys

from .app import ControlCenter
from .constants import VIEWS
from .gather import _default_state, gather_fast_state
from .state_file import (
    acquire_lock,
    process_alive,
    read_state,
    release_lock,
    write_state,
)
from .theme import load_colors


def main():
    initial = "home"
    start_hidden = False
    args = sys.argv[1:]
    if len(args) > 2:
        print(
            f"usage: control-center [--daemon] [{'|'.join(VIEWS)}]",
            file=sys.stderr,
        )
        return 2
    for arg in args:
        if arg in VIEWS:
            initial = arg
        elif arg == "--daemon":
            start_hidden = True
        elif arg in ("-h", "--help"):
            print(f"usage: control-center [--daemon] [{'|'.join(VIEWS)}]")
            return 0
        else:
            print(
                f"usage: control-center [--daemon] [{'|'.join(VIEWS)}]",
                file=sys.stderr,
            )
            return 2

    acquire_lock()
    state = read_state()
    pid = state.get("pid")
    current = state.get("view")
    visible = bool(state.get("visible", False))
    if isinstance(pid, int) and process_alive(pid):
        if start_hidden:
            release_lock()
            return 0
        write_state(pid, initial, not (visible and current == initial))
        release_lock()
        os.kill(pid, signal.SIGUSR1)
        return 0

    write_state(os.getpid(), initial, not start_hidden)
    release_lock()
    initial_state = _default_state()
    try:
        initial_state = gather_fast_state(initial_state)
    except Exception:
        pass
    app = ControlCenter(initial, load_colors(), initial_state, start_hidden)
    return app.run(None)
