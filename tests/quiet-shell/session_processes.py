"""Signal only an identified shell in the acceptance suite's private session."""

import ctypes
import os
from pathlib import Path
import signal


def _pidfd_functions():
    if hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"):
        return os.pidfd_open, signal.pidfd_send_signal
    # Some standalone Python builds omit these bindings despite libc support.
    libc = ctypes.CDLL(None, use_errno=True)
    try:
        open_fd, send_signal = libc.pidfd_open, libc.pidfd_send_signal
    except AttributeError as error:
        raise RuntimeError("Private restart requires Linux pidfd support") from error
    open_fd.argtypes = (ctypes.c_int, ctypes.c_uint)
    send_signal.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint)

    def checked(result):
        if result < 0:
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code))
        return result

    return lambda pid: checked(open_fd(pid, 0)), lambda fd, sig: checked(send_signal(fd, sig, None, 0))


def terminate_shell(path, session_env, proc_root=Path("/proc")):
    keys = ("XDG_RUNTIME_DIR", "HYPRLAND_INSTANCE_SIGNATURE", "QUIET_FAKE_STATE")
    expected = {key: session_env.get(key, "") for key in keys}
    if not path or not all(expected.values()):
        raise ValueError("Restart requires a shell path and complete private session identity")
    open_fd, send_signal = _pidfd_functions()
    targets = []
    try:
        for proc in proc_root.glob("[0-9]*"):
            handle = None
            try:
                # Open before reading identity: a recycled PID must never receive the signal.
                handle = open_fd(int(proc.name))
                args = (proc / "cmdline").read_bytes().split(b"\0")
                args = [os.fsdecode(arg) for arg in args if arg]
                if not args or Path(args[0]).name not in {"quickshell", "qs", ".quickshell-wrapped", ".qs-wrapped"}:
                    continue
                if "ipc" in args or not any(args[i : i + 2] == ["-p", path] for i in range(len(args) - 1)):
                    continue
                raw = (proc / "environ").read_bytes().split(b"\0")
                actual = dict(os.fsdecode(entry).split("=", 1) for entry in raw if b"=" in entry)
                if any(actual.get(key) != value for key, value in expected.items()):
                    continue
                targets.append((int(proc.name), handle))
                handle = None
            except (OSError, ValueError):
                # Disappeared or unobservable processes are never candidates.
                continue
            finally:
                if handle is not None:
                    os.close(handle)
        if len(targets) != 1:
            raise RuntimeError(f"Expected one private shell to restart, found {len(targets)}")
        pid, handle = targets[0]
        send_signal(handle, signal.SIGTERM)
        return pid
    finally:
        for _, handle in targets:
            os.close(handle)
