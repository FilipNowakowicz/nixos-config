# Quiet shell tests

`tests/packages/quiet-shell-status.nix` runs in CI. It checks `status.py` against the
fake system commands, and with no commands at all.

`acceptance.py` needs a GPU-backed private desktop, so it runs by hand. It uses real
pointer and keyboard input inside a nested Hyprland, and never touches the running
session. Every command the shell calls is faked by `fakes/fake.py`, which can also fail
a command or make it succeed without changing anything.

1. Create a GPU session with Agent Desktop and these variables.
   Use the Mesa that matches its runtime, or `labwc` cannot start EGL.

   ```sh
   AGENT_DESKTOP_RENDERER=gles2 AGENT_DESKTOP_RENDER_DEVICE=/dev/dri/renderD128 \
   GBM_BACKENDS_PATH=$MESA/lib/gbm \
   __EGL_VENDOR_LIBRARY_FILENAMES=$MESA/share/glvnd/egl_vendor.d/50_mesa.json \
   uv run agent-desktop create --guard-host
   ```

2. Launch `nested.sh RUNDIR` in that session with `qs` on `PATH`. Set
   `QUIET_REAL_CONFIG=1` and `QUIET_COMMAND=quiet-shell` to test the built package with
   the repo's real `hyprland.lua`.

3. The nested window gets no frames from a headless parent, so add an output Hyprland
   renders itself, and always give `grim` a timeout:

   ```sh
   q.sh RUNDIR hyprctl output create headless
   q.sh RUNDIR hyprctl eval 'hl.monitor({output="HEADLESS-1",mode="1920x1080@60",position="1920x0",scale=1})'
   q.sh RUNDIR hyprctl dispatch 'hl.dsp.focus({monitor="HEADLESS-1"})'
   ```

4. Open two windows with `kitty -o confirm_os_window_close=0`, since some tests close them,
   then run the suite with `wlrctl`, `wtype`, `notify-send`, `grim`
   and `qs` on `QUIET_TOOLS`:

   ```sh
   QUIET_TOOLS=... python3 acceptance.py RUNDIR HEADLESS-1 [name-filter]
   ```

Set `QUIET_TRAY_PYTHON` to a Python with `dbus-next` to include the tray test, which uses
`fakes/tray.py`. Start from a fresh session each run, because tests pair a device and close
windows.

`drag.py` presses, drags and releases with a virtual pointer, which `wlrctl` can't do.
Password requests use `fakes/TestAuth.qml`, because the private session has no system bus,
so the real polkit flow has to be tried by hand with `pkexec true`.

Not covered: physical `SUPER` chords, because `wtype` chords do not match binds; real
network, Bluetooth and audio changes; and hardware frame pacing.

## Trying it on real hardware

`try-tty.sh` starts a second Hyprland with the built shell and the real `hyprland.lua`.
It needs no rebuild and changes nothing in `~/.config`. Press Ctrl+Alt+F2, log in and run
it, then use Ctrl+Alt+F1 and Ctrl+Alt+F2 to move between sessions. Leave with
SUPER+SHIFT+Escape.

If the screen hangs, try Ctrl+Alt+F1 before the power button. Each run moves the last
run's logs to `hyprland.previous.log` and `shell.previous.log`, so a hang leaves evidence.

Sleep and idle are inhibited until you leave, because hypridle in the first session can't
see input in the second and would otherwise suspend the machine. Hyprland imports its environment into the shared systemd user manager and stops
`graphical-session.target` on exit, which would take down the first session's services.
The launcher filters those calls, and logs what it filtered to `held-back.log`.

The session has its own D-Bus, so the shell can own notifications while mako keeps
running in the first session. Apps there can't see apps here: media playing on tty1 won't
appear, and Firefox can't open the same profile twice.
