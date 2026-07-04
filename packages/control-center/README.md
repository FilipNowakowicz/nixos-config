# Control Center

A unified system control panel for Wayland compositors, built with GTK4 and
the GTK4 layer shell. It presents one panel anchored to the top-right of the
screen with quick access to Wi-Fi, Bluetooth, VPN (Tailscale + Mullvad), audio,
brightness, power profile, do-not-disturb, theme switching, and media controls.

It is packaged as a first-class flake output rather than a loose script:

```sh
nix run  '.#control-center'          # launch the panel
nix run  '.#control-center' -- wifi  # open straight to a view
nix build '.#control-center'         # build the wrapped binary
```

`control-center --daemon` starts hidden; a running instance is toggled by
sending `SIGUSR1` (the repo wires this to a keybind), and `SIGUSR2` reloads
theme colours.

## Runtime dependencies

The packaged derivation pins every backing tool on `PATH` through the gApps
wrapper, so a `nix run`/`nix build` install needs nothing extra. The lists
below document what each surface talks to — useful when reusing the source
outside this flake.

### Required

Without these the panel still launches, but the corresponding surface is empty:

| Tool                           | Used for                                   |
| ------------------------------ | ------------------------------------------ |
| GTK4 + `gtk4-layer-shell`      | the panel window itself (hard requirement) |
| `python3` + `pygobject3`       | the application runtime                    |
| NetworkManager (`nmcli`)       | Wi-Fi radio, scan list, connection state   |
| BlueZ (D-Bus) + `bluetoothctl` | Bluetooth adapter/device state and actions |
| WirePlumber (`wpctl`)          | sink/source volume, mute, device picker    |

Bluetooth, power profile, and media (MPRIS) state are read over D-Bus, so they
degrade to an empty/idle panel when the relevant service is not running rather
than erroring. Now Playing only tracks the MPRIS sources listed in
`NOW_PLAYING_ALLOW` (`constants.py`) — Spotify by default, so browser/video tabs
(YouTube, etc.) don't hijack the media row; add players there or set it to `()`
to track whatever is playing.

### Optional integrations

These **degrade gracefully**: when the backing CLI is absent the related
control is shown disabled and labelled _Not installed_ instead of presenting a
dead toggle that silently does nothing. Presence is probed once at startup (see
[`capabilities.py`](src/control_center/capabilities.py)).

| Capability    | Tool             | Behaviour when absent                                             |
| ------------- | ---------------- | ----------------------------------------------------------------- |
| `tailscale`   | `tailscale`      | VPN view's Tailscale section disabled; tile reads _Not installed_ |
| `mullvad`     | `mullvad`        | VPN view's Mullvad section + relay picker disabled                |
| `brightness`  | `brightnessctl`  | brightness slider disabled, shows `n/a`                           |
| `night_light` | `wlsunset`       | "Night Light" quick toggle disabled                               |
| `dnd`         | `makoctl` (Mako) | Do-Not-Disturb tile/view disabled                                 |

A few extras are used opportunistically and already no-op safely when missing:
`power-profiles-daemon` (`powerprofilesctl`), `curl` (IP geolocation for night
light), `nm-connection-editor`, `blueman-manager`, `pavucontrol`, and `kitty`
(launched for the "VPN tools" / notification-config helpers via `shutil.which`).

## Assumptions

- A **wlroots-based Wayland compositor** with `wlr-layer-shell` support
  (developed against Hyprland). It will not run on X11 or GNOME's Mutter.
- A **Nerd Font** is installed (JetBrainsMono Nerd Font here); the UI uses font
  glyphs rather than embedded icons.
- Theme colours are read from `~/nix/home/theme/active.nix`; absent that file
  the built-in defaults in `constants.py` are used. The "Theme" picker shells
  out to a `theme-switch` command that only exists in this repo, so that one
  control is repo-specific.

## How graceful degradation is wired

- `capabilities.py` maps each optional capability to its backing executable and
  resolves availability with `shutil.which`, cached for the process lifetime.
- The result is published into the state dict as `caps` by `gather.py`.
- View builders read `state["caps"]` to set widget sensitivity once and adjust
  their refresh labels, so an absent tool reads as _Not installed_ rather than
  _off_.
- Independently, every subprocess call is already failure-tolerant: read paths
  go through `_proc._run` (swallows `FileNotFoundError`/timeout) and write paths
  through `actions._fire` / `_fire_if_found`, so a missing tool can never crash
  the panel.

The capability layer is covered by
[`tests/packages/control-center-capabilities.nix`](../../tests/packages/control-center-capabilities.nix),
which runs without GTK because `capabilities.py` is deliberately stdlib-only.

## Developer Notes

### Layer-shell panel window (`app.py`)

The panel uses a **full-output, 4-edge anchored** layer-shell surface with
`set_exclusive_zone(-1)` (no reservation) so that the transparent root covers
the whole output and a `Gtk.GestureClick` on the root can detect clicks outside
the panel bounds. Two things must be true for this to work:

- **Do not call `set_resizable(False)`** on the window. That single call
  collapses the surface to content size (e.g. 414×608 instead of 1920×1080)
  regardless of the 4-edge anchoring, placing it at the origin with no
  transparent overlay. The panel's top-right placement is achieved via child
  `halign=END` / `valign=START` + margins, not by constraining the window.
- **Dismiss on click-outside-bounds, not focus-leave.** Under Hyprland's
  focus-follows-mouse policy, `EventControllerFocus` fires whenever the cursor
  moves off the panel widget, closing it on hover. Instead: in the
  `GestureClick` handler on the transparent root, call
  `panel.compute_bounds(root)` and dismiss only when the press point is outside
  those bounds. Inner button/slider gestures remain unaffected because GTK
  routes them through the normal event propagation tree.

### Gtk4LayerShell centering (`home/files/scripts/launcher.py`)

Gtk4LayerShell centers a surface automatically along any axis where **neither**
anchor for that axis is set. To center a TOP-anchored surface horizontally,
set `LEFT=False` and `RIGHT=False` — do not set `RIGHT=True` and add a
`monitor_width // 2 + offset` right-margin to approximate center. That approach
silently breaks whenever the bar geometry changes because the offset is
hardcoded to a specific bar layout.

### Releasing the keep-awake inhibitor before power actions (`actions.py`)

The keep-awake inhibitor is started with `--what=handle-lid-switch:idle:sleep
--mode=block`. The `:sleep` flag blocks `systemctl suspend` in addition to
idle-triggered sleep, so any CC action that calls `systemctl suspend` (or
`hibernate`/`reboot` if added later) must call `act_keep_awake(False)` first.
`_fire` is fire-and-forget with no implicit sequencing — without an explicit
release the inhibitor wins and the power action silently does nothing.

### Headless CSS validation

`css.py`, `theme.py`, and `constants.py` are stdlib-only, but importing
`control_center.css` triggers the package `__init__`, which imports `gi` →
`ModuleNotFoundError` in a headless environment. To smoke-check `build_css()`
without GTK or a Wayland display, stub the parent package in `sys.modules`
before loading the submodules:

```python
import sys, types, importlib.util, pathlib

# Prevent __init__ (which imports gi) from running
sys.modules['control_center'] = types.ModuleType('control_center')

src = pathlib.Path('src/control_center')
for name in ('constants', 'theme', 'css'):
    spec = importlib.util.spec_from_file_location(
        f'control_center.{name}', src / f'{name}.py')
    mod = importlib.util.module_from_spec(spec)
    sys.modules[f'control_center.{name}'] = mod
    spec.loader.exec_module(mod)

print(sys.modules['control_center.css'].build_css({}))
```
