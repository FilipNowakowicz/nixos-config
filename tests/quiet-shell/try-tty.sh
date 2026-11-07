#!/usr/bin/env bash
# Try the quiet shell for real in a second Hyprland, without a rebuild or a switch.
# Log in on another TTY and run this. Nothing in ~/.config or the running session changes.
#
# Leave: SUPER+SHIFT+Escape, or Log Out in the shell's system menu.
# Switch between sessions: Ctrl+Alt+F1 and Ctrl+Alt+F2.
#
# Controls are real: Wi-Fi, volume and Shut Down act on the machine. Sleep is held off
# until you leave, including Sleep in the menu and closing the lid.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
self="$repo/tests/quiet-shell/try-tty.sh"
run=${XDG_CACHE_HOME:-$HOME/.cache}/quiet-shell-try
themes=$HOME/.config/themes

# The shell reads one colours file, written here so themes never touch the real links.
write_colors() {
  local css="$themes/$1/waybar-colors.css" list
  color() { sed -n "s/^@define-color $1 #\(.*\);\$/\1/p" "$css"; }
  list=$(find "$themes" -mindepth 1 -maxdepth 1 -type d -printf '"%f",' | sed 's/,$//')
  printf '{"name":"%s","bg":"%s","accent":"%s","text":"%s","themes":[%s]}\n' \
    "$1" "$(color bg)" "$(color amber)" "$(color text)" "$list" >"$run/colors.json"
}

wallpaper() {
  local old
  old=$(cat "$run/swaybg.pid" 2>/dev/null || true)
  # shellcheck disable=SC2016
  setsid -f sh -c 'echo $$ >"$1"; exec swaybg -m fill -i "$2"' sh "$run/swaybg.pid" "$themes/$1/wallpaper" >/dev/null 2>&1
  [[ -z $old ]] || kill "$old" 2>/dev/null || true
}

# Stands in for theme-switch on PATH, so the picker only affects this session.
if [[ ${1:-} == --theme ]]; then
  write_colors "$2"
  wallpaper "$2"
  quiet-shell-ipc reloadTheme
  exit
fi
if [[ ${1:-} == --wallpaper ]]; then
  wallpaper "$2"
  exit
fi

if [[ -z ${QUIET_TRY_NESTED:-} ]] && { [[ -n ${WAYLAND_DISPLAY:-} ]] || [[ -z ${XDG_VTNR:-} ]]; }; then
  echo "Run this from a text login, such as tty2 (Ctrl+Alt+F2)." >&2
  exit 1
fi

# Hyprland can only take the display while this TTY is the one on screen.
if [[ -z ${QUIET_TRY_NESTED:-} ]] && [[ $(loginctl show-session "$XDG_SESSION_ID" -p Active --value) != yes ]]; then
  echo "tty$XDG_VTNR isn't on screen. Switch to it and run this again." >&2
  exit 1
fi

mkdir -p "$run/bin"
# Keep the last run's logs: if a session hangs, the next one must not overwrite the evidence.
for log in hyprland shell; do
  [[ ! -e $run/$log.log ]] || mv "$run/$log.log" "$run/$log.previous.log"
done
echo "Building the shell…"
nix build "$repo#quiet-shell" --out-link "$run/package"

theme=$(basename "$(dirname "$(readlink "$HOME/.local/share/wallpapers/current.png")")")
write_colors "$theme"
# shellcheck disable=SC2016
printf '#!/bin/sh\nexec "%s" --theme "$1"\n' "$self" >"$run/bin/theme-switch"
chmod +x "$run/bin/theme-switch"

# Hyprland imports its environment and starts the session target, then on exit stops
# graphical-session.target and clears that environment. The systemd user manager is shared,
# so without this filter leaving here takes down waybar, mako and hypridle on the first TTY.
cat >"$run/bin/systemctl" <<SHIM
#!/usr/bin/env bash
case " \$* " in
  *" graphical-session.target "* | *" hyprland-session.target "* | *-environment*)
    echo "\$*" >>"$run/held-back.log"
    exit 0
    ;;
esac
PATH=\${PATH#"$run/bin:"} exec systemctl "\$@"
SHIM
chmod +x "$run/bin/systemctl"
: >"$run/held-back.log"

# The lock screen from this checkout, since ~/.config still has the installed one.
sed "s|~/.config/hypr/lock-status|bash '$repo/home/files/hypr/lock-status.sh'|" \
  "$repo/home/files/hypr/hyprlock.conf" >"$run/hyprlock.conf"
rm -f "$run/bin/hyprlock"
# shellcheck disable=SC2016
printf '#!/bin/sh\nexec "%s" -c "%s" "$@"\n' "$(command -v hyprlock)" "$run/hyprlock.conf" >"$run/bin/hyprlock"
chmod +x "$run/bin/hyprlock"

cat >"$run/hypr.lua" <<LUA
-- The real config, with the quiet shell on and the autostart replaced below.
local real_loadfile = loadfile
loadfile = function(path, ...)
  if path and path:match("/%.config/hypr/shell%.lua$") then
    return function() return { quiet = true } end
  end
  return real_loadfile(path, ...)
end
dofile("$repo/home/files/hypr/hyprland.lua")
hl.bind("SUPER + SHIFT + Escape", hl.dsp.exit())
hl.on("hyprland.start", function()
  hl.exec_cmd("'$self' --wallpaper '$theme'")
  hl.exec_cmd("quiet-shell >'$run/shell.log' 2>&1")
end)
LUA

# DESKTOP_TEST skips the autostart, which would repoint the user services at this
# session. The private bus keeps mako from holding the notification name.
export DESKTOP_TEST=1 QUIET_COLORS="$run/colors.json" XDG_SESSION_TYPE=wayland HYPRLAND_NO_SD_VARS=1
export PATH="$run/bin:$run/package/bin:$PATH"
unset HYPRLAND_INSTANCE_SIGNATURE DISPLAY
[[ -n ${QUIET_TRY_NESTED:-} ]] || unset WAYLAND_DISPLAY

echo "Starting. Leave with SUPER+SHIFT+Escape. Logs: $run"
# hypridle in the first session can't see input here, so it would lock and then suspend.
inhibit=(systemd-inhibit --what=sleep:idle --who=quiet-shell-try --why="Trying the quiet shell")
[[ -z ${QUIET_TRY_NESTED:-} ]] || inhibit=()
status=0
"${inhibit[@]}" dbus-run-session -- start-hyprland -- -c "$run/hypr.lua" >"$run/hyprland.log" 2>&1 || status=$?
kill "$(cat "$run/swaybg.pid" 2>/dev/null)" 2>/dev/null || true
# start-hyprland exits 0 even when Hyprland crashes.
if grep -q 'Hyprland has crashed' "$run/hyprland.log"; then
  status=1
  echo "Hyprland crashed. See the end of $run/hyprland.log" >&2
fi
echo "Session ended (status $status). Logs: $run"
exit "$status"
