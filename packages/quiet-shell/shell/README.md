# Quiet shell

A quiet, auto-hiding desktop shell for Hyprland, built on Quickshell.

Everything goes through `scripts/status.sh` and ordinary system commands, so tests
swap those commands with fakes rather than using a separate test mode.

Fonts: Open Runde (SIL OFL, see `assets/fonts/OFL.txt`).
Icons: Lucide 0.469 (ISC).

## Agent requests

`Agents.qml` follows Agent Desktop's event stream (`agent-desktop events --follow`).
When an agent asks you to take a private session, for example to sign in, or asks to
use your screen, an urgent banner appears with the commands the event carries:
Take control and Paste and take, or Allow and Decline. The banner shows even in
Focus. Nothing is answered without a click, and the banner goes away once the request
is answered, withdrawn or taken elsewhere. The stream needs `agent-desktop` on `PATH`,
for example after `uv tool install --editable ~/agent-desktop`, or a command in
`QUIET_AGENT_EVENTS`. Without either, the shell checks again every 30 seconds.
