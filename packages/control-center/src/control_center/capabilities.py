"""Runtime capability detection for optional integrations.

The packaged derivation pins every backing tool on ``PATH`` via the gApps
wrapper, so all capabilities resolve true there. Detection only matters for
*external reuse*, where the source may run on a system that is missing some
tools. Views use this to distinguish "tool absent" from "feature off" instead
of showing a dead control that silently does nothing.

Pure stdlib (no ``gi`` import) so it stays unit-testable without GTK.
"""

import functools
import shutil

# Capability name -> the CLI executable that backs it. Only the *optional*
# integrations live here: each one's read path already returns an "off" default
# when the tool is missing, so gating the UI on presence is safe and honest.
# Core deps (nmcli, wpctl) are documented as required in the package README
# rather than degraded, because without them the panel has little to show.
CAPABILITY_TOOLS = {
    "tailscale": "tailscale",
    "mullvad": "mullvad",
    "brightness": "brightnessctl",
    "night_light": "wlsunset",
    "dnd": "makoctl",
}


def detect(tools=None):
    """Return ``{capability: bool}`` for the given tool map (defaults to
    :data:`CAPABILITY_TOOLS`). A capability is available when its executable is
    resolvable on ``PATH``."""
    tools = CAPABILITY_TOOLS if tools is None else tools
    return {name: shutil.which(exe) is not None for name, exe in tools.items()}


@functools.cache
def capabilities():
    """Process-lifetime cached :func:`detect` result. Tool install/uninstall
    mid-session is not a case worth re-probing every poll tick."""
    return detect()
