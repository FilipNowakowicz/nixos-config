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

Bluetooth device connections also use ordered requests and fresh state confirmation.
Rows expose Connect/Disconnect, with Connecting/Disconnecting progress. Failed
writes remain retryable; late state can reconcile a timeout without repeating the
command. A new click derives its target from current intent rather than an obsolete
captured connection state. Targets are validated device addresses.

The redundant Scan action is removed: the panel lists paired devices, and its old
Scan action immediately opened another application. Pair new device now explicitly
opens Bluetooth Settings, without launching a background scan. Failed process
startup or a missing tool keeps the panel open with a visible error. Successful
process startup is a handoff, not proof that a device was paired.

Decorative microphone metering and inactive Detect/Test controls are removed.
DND presets replace the previous timer, so an obsolete timer cannot override
Always or a later manual toggle. DND changes preserve unrelated notification modes.

## Validation and limits

The focused check covers process identity, exact launcher submission, DND mode
preservation and fourteen ordered-write/readback regression cases, plus settings-launch failures:

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

Audio-device/relay selection, WiFi connections, keep-awake/night-light and other
launch actions retain their previous completion workflow. Bluetooth pairing remains
a deliberate external settings handoff; integrated discovery is a later feature. Application search, window switching,
minimize/restore, dock and notification history are subsequent work.

Retain the working system generation. Production activation and physical hardware
acceptance are separate steps after review; a build is not an activation.

Private Bluetooth trials additionally covered delayed connect/disconnect, rejection
and explicit Retry, timeout with late readback, rapid reversal under reduced motion,
and successful/missing-settings pairing handoffs. All command writes were mocked;
no physical Bluetooth adapter or personal settings application was changed.
