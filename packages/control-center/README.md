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
than erroring.

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

## Demo

[`launcher-preview.html`](launcher-preview.html) is a static HTML mock of the
panel layout, kept only as supporting visual material. It is not the project
pitch and is not wired into the build.
