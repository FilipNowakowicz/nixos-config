# Desktop interaction preview

This change prepares a desktop interaction prototype. It follows the Hyprland Lua
migration and does not activate the prototype or change the running session.

## Behaviour

- Launcher: native text selection/editing, Unicode and word navigation. Enter
  runs the typed command; Tab/Right explicitly accept completion. Failed commands
  preserve the query for correction. Status polling runs off the input thread.
- Control centre: native scales/switches, accessible names and checked/value
  states, visible audio-device navigation and truthful settings feedback.
- Common settings: ordered/coalesced requests, pending status, fresh readback
  before confirmation, and Retry after failure or an unconfirmed timeout. Mute
  uses an explicit target rather than toggling again on Retry.
- Device lists: polling preserves rows and focus when unchanged; changed devices
  restore focus by identity, with a nearby row chosen if a device disappears.
- Presentation: long views scroll within the output; output resizing updates the
  limit; reduced motion disables view/reveal/CSS transitions. The active theme
  remains the source of colours.
- Session isolation: runtime state is scoped to the Wayland session. Daemon
  handoff verifies process start time and pins signalling with a process fd.

Decorative microphone metering and inactive Detect/Test controls are removed.
DND presets replace the previous timer, so an obsolete timer cannot override
Always or a later manual toggle. DND changes preserve unrelated notification modes.

## Validation and limits

The focused check covers process identity, exact launcher submission, DND mode
preservation and thirteen ordered-write/readback regression cases:

```sh
nix build .#checks.x86_64-linux.control-center-capabilities --no-link
bash scripts/validate.sh flake-eval
bash scripts/validate.sh host main-ci
```

Local guarded headless input/accessibility trials also covered delayed success,
failure/Retry, timeout/readback, rapid input, six GTK state/focus/motion probes,
800×600 scrolling, live resizing to 1024×768 and native launcher editing.
Their command backends were mocked. They prove UI dispatch and reconciliation,
not physical radio/audio changes, GPU frame pacing or everyday usability.

Device/relay selection, scans, keep-awake/night-light and launch actions retain
their previous completion workflow. Application search, window switching,
minimize/restore, dock and notification history are subsequent work.

Retain the working system generation. Production activation and physical hardware
acceptance are separate steps after review; a build is not an activation.
