"""Unit tests for control_center.capabilities.

Loaded by tests/packages/control-center-capabilities.nix, which runs this
under a plain python3 (no GTK / gi) with the module path as argv[1]. The
capabilities module is stdlib-only by design so it can be exercised here
without the GObject stack the rest of the package needs.
"""

import importlib.util
import sys


def _load(path):
    spec = importlib.util.spec_from_file_location("cc_caps", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(path):
    caps = _load(path)

    # The optional-integration set is the public contract the views gate on.
    assert set(caps.CAPABILITY_TOOLS) == {
        "tailscale", "mullvad", "brightness", "night_light", "dnd",
    }, caps.CAPABILITY_TOOLS

    # Injected map: a resolvable binary is True, a missing one is False.
    injected = caps.detect({
        "present": "python3",
        "absent": "control-center-definitely-not-a-real-binary",
    })
    assert injected == {"present": True, "absent": False}, injected

    # Default detect() covers every declared capability with booleans.
    real = caps.detect()
    assert set(real) == set(caps.CAPABILITY_TOOLS), real
    assert all(isinstance(v, bool) for v in real.values()), real

    # capabilities() is cached for the process lifetime.
    assert caps.capabilities() is caps.capabilities()

    print("control-center capabilities tests passed")


if __name__ == "__main__":
    main(sys.argv[1])
