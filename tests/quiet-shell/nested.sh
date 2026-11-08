#!/usr/bin/env bash
# Run the quiet shell inside a private nested Hyprland with faked system commands.
# Start this inside an Agent Desktop session. It never touches the running desktop.
# Usage: nested.sh RUNDIR [theme-json]
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
run=${1:?run directory}
mkdir -p "$run/bin" "$run/power/BAT0" "$run/apps" "$run/kitty"
# Tests close windows, and kitty's confirmation would otherwise stop them.
echo 'confirm_os_window_close 0' >"$run/kitty/kitty.conf"
export KITTY_CONFIG_DIRECTORY="$run/kitty"
# Unix socket paths are limited to about 108 bytes, so keep this one short.
rt=$(mktemp -d "/run/user/$(id -u)/q.XXXX")
unset HYPRLAND_INSTANCE_SIGNATURE
for c in nm-connection-editor hyprlock grim slurp curl khal fd xdg-open cliphist wl-copy nmcli bluetoothctl tailscale mullvad wpctl pw-dump pw-metadata brightnessctl powerprofilesctl playerctl quiet-buds pgrep pkill systemctl systemd-run theme-switch setsid; do
  ln -sf "$repo/tests/quiet-shell/fakes/fake.py" "$run/bin/$c"
done
echo 64 >"$run/power/BAT0/capacity"
echo Discharging >"$run/power/BAT0/status"
export QUIET_TEST_AUTH="file://$repo/tests/quiet-shell/fakes/TestAuth.qml"
# Spotlight's memory and exchange rates stay with the run, not the real home.
export XDG_STATE_HOME="$run/state"
# An app with its own actions, which run a fake so tests can see them.
export XDG_DATA_HOME="$run/data"
mkdir -p "$XDG_DATA_HOME/applications"
cat >"$XDG_DATA_HOME/applications/quiet-notes.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Quiet Notes
Exec=nm-connection-editor notes
Actions=new-note;
[Desktop Action new-note]
Name=New Note
Exec=nm-connection-editor new-note
DESKTOP
export QUIET_TIMEZONE=Europe/Warsaw QUIET_FAKE_STATE="$run/state.json" QUIET_COLORS="$run/colors.json" QUIET_POWER_SUPPLY="$run/power"
[[ -f $QUIET_COLORS ]] || cat >"$QUIET_COLORS" <<'JSON'
{"name":"gilded-contours","bg":"071126","accent":"d3ad7a","text":"f0d5a2",
 "themes":["acid-statue","cold-concrete","desert-dusk","gilded-contours","lunar-peaks","mono-mesh","nighthawks","obsidian-ridge"]}
JSON
# Keybindings call quiet-shell-ipc, which sits next to the built shell.
[[ ${QUIET_COMMAND:-} != */* ]] || PATH="$(dirname "$QUIET_COMMAND"):$PATH"
parent=$WAYLAND_DISPLAY
[[ $parent == /* ]] || parent="$XDG_RUNTIME_DIR/$parent"
cat >"$run/hypr.lua" <<LUA
hl.config({
  general = { gaps_in = 8, gaps_out = 12, border_size = 2, col = { active_border = "rgb(d3ad7a)", inactive_border = "rgb(0d1830)" } },
  decoration = { rounding = 12, blur = { enabled = true, size = 8, passes = 3, vibrancy = 0.17, ignore_opacity = false } },
  animations = { enabled = true },
  misc = { disable_hyprland_logo = true, disable_splash_rendering = true, force_default_wallpaper = 0 },
})
hl.monitor({ output = "", mode = "1920x1080@60", position = "auto", scale = 1 })
hl.layer_rule({ name = "quiet-glass", match = { namespace = "quiet-shell" }, blur = true, ignore_alpha = 0.02 })
LUA
config="$run/hypr.lua"
hypr_home=$HOME
# QUIET_REAL_CONFIG=1 loads the repo's own hyprland.lua. It reads colours from
# $HOME, so give the compositor a private home rather than write into the real one.
if [[ ${QUIET_REAL_CONFIG:-} == 1 ]]; then
  hypr_home="$run/home"
  mkdir -p "$hypr_home/.config/hypr"
  echo 'return { active = "rgb(d3ad7a)", inactive = "rgb(0d1830)", shadow = "rgba(071126cc)" }' >"$hypr_home/.config/hypr/colors.lua"
  config="$repo/home/files/hypr/hyprland.lua"
  export DESKTOP_TEST=1
fi
HOME="$hypr_home" XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY="$parent" Hyprland -c "$config" >"$run/hyprland.log" 2>&1 &
hypr=$!
trap 'kill $hypr 2>/dev/null || true; rm -rf "$rt"' EXIT
for _ in $(seq 1 60); do
  sock=$(find "$rt/hypr" -name .socket.sock -type s 2>/dev/null | head -1) || true
  [[ -n $sock ]] && break
  sleep .2
done
[[ -n $sock ]]
export HYPRLAND_INSTANCE_SIGNATURE XDG_RUNTIME_DIR="$rt"
HYPRLAND_INSTANCE_SIGNATURE=$(basename "$(dirname "$sock")")
export WAYLAND_DISPLAY
WAYLAND_DISPLAY=$(find "$rt" -maxdepth 1 -type s -name 'wayland-*' | head -1 | xargs basename)
export PATH="$run/bin:$PATH"
echo "$HYPRLAND_INSTANCE_SIGNATURE" >"$run/signature"
env | grep -E '^(HYPRLAND_INSTANCE_SIGNATURE|WAYLAND_DISPLAY|XDG_RUNTIME_DIR|QUIET_|PATH|DBUS)' >"$run/env"
[[ -n ${QUIET_WALLPAPER:-} ]] && swaybg -m fill -i "$QUIET_WALLPAPER" &
# Keep retrying so a QML error can be fixed without restarting the compositor.
while true; do
  ${QUIET_COMMAND:-qs -p "$repo/packages/quiet-shell/shell"} >"$run/qs.log" 2>&1 || true
  sleep 1
done
