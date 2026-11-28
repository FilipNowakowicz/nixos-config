# Quiet shell

A quiet, auto-hiding desktop shell for Hyprland, built on Quickshell.

Everything goes through `scripts/status.sh` and ordinary system commands, so tests
swap those commands with fakes rather than using a separate test mode.

Fonts: Open Runde (SIL OFL, see `assets/fonts/OFL.txt`).
Icons: Lucide 0.469 (ISC).

## Battery warnings

`Sys.qml` warns at 30%, 15% and 5% while discharging. The 30% banner hides by
itself and Focus silences it. The 15% and 5% banners show even in Focus and stay
until dismissed or the laptop starts charging. Only the latest warning is kept.

## Agents

`AgentStatus.qml` reads every running Claude Code and Codex session from
`scripts/agents.py`: its state (working, idle, or waiting on you, from Claude Code's
own registry), its title, what it is doing now, your last prompt and its last reply,
the subagents it has running, how full its context is, its cost, and the usage limits
with when they run out at the current pace. Three places show them:

- the overview's card,
- the agents panel (SUPER+A, or the agents button in the bar), and
- the peek, a small pill at the top right while the bar is hidden, when one needs you
  (or, if chosen, has just finished).

Each view comes in a style: Compact (a line each), Detailed (everything above, with
subagents beneath their session), Pets (a little text creature per session whose face
and words follow what it does) or Feed (every agent's last steps in one list). The
panel's Customise button (or `c`) picks the panel's and the card's styles, what the
bar shows (a dot, a count, the face of the session that matters most, or nothing),
when the peek appears, and which lines to show. The choices are kept in
`$XDG_STATE_HOME/quiet-shell/agents.json`. In the panel, `s` cycles the style and
1–9 go to that session's terminal.

While a view is open it asks for everything every 4 seconds. Otherwise, while the
indicator or the peek is on, it asks every 10 seconds for the brief version (states
and titles, no transcripts or terminals). `QUIET_AGENTS` replaces the command, as
the smoke test does with made-up sessions.

## Agent requests

`Agents.qml` follows Agent Desktop's event stream (`agent-desktop events --follow`).
When an agent asks you to take a private session, for example to sign in, an urgent
banner appears with the commands the event carries: Take control, and Paste and
take for a login. The banner shows even in Focus. Nothing is taken without a click,
and the banner goes away once the request is withdrawn or taken elsewhere. Requests
to use your own screen are not shown here: the agent's client asks for those, or
Agent Desktop sends its own notification. The stream needs `agent-desktop` on
`PATH`, for example after `uv tool install --editable ~/agent-desktop`, or a command
in `QUIET_AGENT_EVENTS`. Without either, the shell checks again every 30 seconds.
