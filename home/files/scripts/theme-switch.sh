#!/bin/bash
set -euo pipefail

THEME="${1:-}"
THEMES_DIR="$HOME/.config/themes"
REPO_THEMES_DIR="$NIX_REPO/home/theme/themes"
REPO_WALLPAPERS_DIR="$NIX_REPO/home/theme/wallpapers"
ACTIVE_FILE="$NIX_REPO/home/theme/active.nix"
LINKS_FILE="$THEMES_DIR/links.sh"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/theme-switch.lock"
WAYBAR_PENDING_RELOAD="${XDG_STATE_HOME:-$HOME/.local/state}/waybar/needs-reload"

exec 9>"$LOCK_FILE"
flock 9

list_themes() {
  find "$REPO_THEMES_DIR" -maxdepth 1 -type f -name '*.nix' -printf '%f\n' |
    sed 's/\.nix$//' |
    sort
}

theme_exists() {
  [[ -f "$REPO_THEMES_DIR/$1.nix" ]]
}

theme_value() {
  local theme_file="$1"
  local key="$2"
  grep -oP "${key}\\s*=\\s*\"\\K[^\"]+" "$theme_file" | head -1
}

theme_wallpaper() {
  local theme_file="$1"
  grep -oP 'wallpaper\s*=\s*\.\./wallpapers/\K[^;]+' "$theme_file" | head -1
}

waybar_pids() {
  ps -eo pid=,comm=,args= |
    awk '$2 == ".waybar-wrapped" && $3 == "waybar" { print $1 }
         $2 == "waybar" { print $1 }' |
    sort -n -u
}

swaybg_pids() {
  ps -eo pid=,comm=,args= |
    awk '($2 == "swaybg" || $2 == ".swaybg-wrapped") && $0 ~ /swaybg -m fill -i .*current[.]png/ { print $1 }' |
    sort -n -u
}

waybar_visible() {
  # Visible waybar sits at layer level 2 ("top"); SIGUSR1 drops it to level 1
  # ("bottom") where it stays running but unseen. Checking the layer level is
  # the authoritative signal — the launcher uses the same check.
  hyprctl layers 2>/dev/null | awk '
    /^[[:space:]]*Layer level 2/  { in_top = 1; next }
    /^[[:space:]]*Layer level/    { in_top = 0; next }
    in_top && /namespace: waybar/ { found = 1; exit }
    END { exit !found }
  '
}

ensure_theme_assets() {
  local theme="$1"
  local theme_dir="$THEMES_DIR/$theme"
  local theme_file="$REPO_THEMES_DIR/$theme.nix"
  local bg brown orange amber text wallpaper

  [[ -d $theme_dir ]] && return 0
  theme_exists "$theme" || return 1

  bg=$(theme_value "$theme_file" bg)
  brown=$(theme_value "$theme_file" brown)
  orange=$(theme_value "$theme_file" orange)
  amber=$(theme_value "$theme_file" amber)
  text=$(theme_value "$theme_file" text)
  wallpaper=$(theme_wallpaper "$theme_file")

  if [[ -z $bg || -z $brown || -z $orange || -z $amber || -z $text || -z $wallpaper ]]; then
    echo "Error: could not parse theme definition: $theme_file" >&2
    return 1
  fi

  mkdir -p "$theme_dir"

  cat >"$theme_dir/kitty-theme.conf" <<EOF
# vim:ft=kitty
## name: $theme

foreground           #$text
background           #$bg
selection_foreground #$text
selection_background #$brown

cursor            #$amber
cursor_text_color #$bg

url_color #$amber

active_border_color   #$amber
inactive_border_color #$brown
bell_border_color     #$orange

wayland_titlebar_color #$bg

active_tab_foreground   #$text
active_tab_background   #$bg
inactive_tab_foreground #$brown
inactive_tab_background #$bg
tab_bar_background      #$bg

# 16 colors - extended palette
color0  #$bg
color8  #$brown
color1  #cc241d
color9  #fb4934
color2  #98971a
color10 #b8bb26
color3  #$amber
color11 #fabd2f
color4  #458588
color12 #83a598
color5  #b16286
color13 #d3869b
color6  #689d6a
color14 #8ec07c
color7  #$text
color15 #fbf1c7
EOF

  cat >"$theme_dir/hypr-colors.conf" <<EOF
\$col_active   = rgb($amber)
\$col_inactive = rgb($brown)
\$col_shadow   = rgba(${bg}cc)
EOF

  cat >"$theme_dir/hyprlock-colors.conf" <<EOF
\$text   = rgb($text)
\$bg     = rgb($bg)
\$amber  = rgb($amber)
\$orange = rgb($orange)
EOF

  cat >"$theme_dir/waybar-colors.css" <<EOF
@define-color bg #$bg;
@define-color brown #$brown;
@define-color orange #$orange;
@define-color amber #$amber;
@define-color text #$text;
EOF

  cat >"$theme_dir/mako-config" <<EOF
font=JetBrainsMono Nerd Font 11
background-color=#$bg
text-color=#$text
border-color=#$orange
border-radius=8
border-size=2
anchor=top-right
margin=12
padding=10,14
width=300
default-timeout=5000
max-visible=5

[mode=do-not-disturb]
invisible=1
EOF

  ln -sf "$REPO_WALLPAPERS_DIR/$wallpaper" "$theme_dir/wallpaper"
}

# Get current theme from active.nix
if [[ -f $ACTIVE_FILE ]]; then
  CURRENT_THEME=$(grep -oP 'themes/\K[^.]+' "$ACTIVE_FILE" 2>/dev/null || echo "unknown")
else
  CURRENT_THEME="unknown"
fi

# List available themes if no argument
if [[ -z $THEME ]]; then
  echo "Available themes:"
  list_themes
  echo ""
  echo "Current theme: $CURRENT_THEME"
  echo ""
  echo "Usage: theme-switch <theme-name>"
  exit 0
fi

# Validate theme exists
if ! theme_exists "$THEME"; then
  echo "Error: Theme not found: $THEME"
  echo "Available themes:"
  list_themes
  exit 1
fi

# Check if already active
if [[ $CURRENT_THEME == "$THEME" ]]; then
  if [[ -z $(swaybg_pids) ]]; then
    swaybg -m fill -i "$HOME/.local/share/wallpapers/current.png" 9>&- &
    echo "Theme '$THEME' is already active; restarted wallpaper"
  else
    echo "Theme '$THEME' is already active"
  fi
  exit 0
fi

# Update active.nix
if [[ ! -f $ACTIVE_FILE ]]; then
  echo "Error: $ACTIVE_FILE not found"
  exit 1
fi

echo "import ./themes/$THEME.nix" >"$ACTIVE_FILE"
echo "Updated active.nix to $THEME"

# Reuse the generated symlink map from Home Manager to avoid duplicating paths.
if [[ ! -f $LINKS_FILE ]]; then
  echo "Error: $LINKS_FILE not found"
  exit 1
fi

# shellcheck source=/dev/null
source "$LINKS_FILE"
ensure_theme_assets "$THEME"
link_theme_assets "$THEMES_DIR/$THEME"
theme_file="$REPO_THEMES_DIR/$THEME.nix"
bg=$(theme_value "$theme_file" bg)
brown=$(theme_value "$theme_file" brown)
amber=$(theme_value "$theme_file" amber)

if [[ -f /tmp/control-center.json ]]; then
  control_center_pid=$(
    sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p' \
      /tmp/control-center.json | head -1
  )
  if [[ -n ${control_center_pid:-} ]] && kill -0 "$control_center_pid" 2>/dev/null; then
    kill -USR2 "$control_center_pid" 2>/dev/null || true
  fi
fi

# Reload apps
hyprctl keyword general:col.active_border "rgb($amber)" >/dev/null 2>&1 || true
hyprctl keyword general:col.inactive_border "rgb($brown)" >/dev/null 2>&1 || true
hyprctl keyword decoration:shadow:color "rgba(${bg}cc)" >/dev/null 2>&1 || true

if waybar_visible; then
  while IFS= read -r pid; do
    [[ -n $pid ]] || continue
    kill -USR2 "$pid" 2>/dev/null || true
  done < <(waybar_pids)
  rm -f "$WAYBAR_PENDING_RELOAD"
else
  # Defer the reload until the bar is un-hidden so SIGUSR2 doesn't bring it
  # back into view. waybar-toggle consumes this flag on its next show.
  mkdir -p "$(dirname "$WAYBAR_PENDING_RELOAD")"
  : >"$WAYBAR_PENDING_RELOAD"
fi

# Warm the kernel page cache so swaybg's decode is CPU-bound, not disk-bound.
# Cold reads of large wallpapers (mono-mesh.jpg 5.2M, desert-dusk.png 8M) push
# the buffer commit past the handover window and the compositor briefly falls
# back to its default wallpaper.
cat "$HOME/.local/share/wallpapers/current.png" >/dev/null 2>&1 || true

old_swaybg_pids=()
while IFS= read -r pid; do
  [[ -n $pid ]] && old_swaybg_pids+=("$pid")
done < <(swaybg_pids)
swaybg -m fill -i "$HOME/.local/share/wallpapers/current.png" 9>&- &
sleep 0.5
if ((${#old_swaybg_pids[@]} > 0)); then
  kill "${old_swaybg_pids[@]}" 2>/dev/null || true
  sleep 0.2
  for pid in "${old_swaybg_pids[@]}"; do
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  done
fi

ps -eo pid=,comm= |
  awk '$2 == ".kitty-wrapped" || $2 == "kitty" { print $1 }' |
  xargs -r kill -USR1 2>/dev/null || true

if ! systemctl --user restart mako.service 2>/dev/null; then
  pkill -x mako 2>/dev/null || true
  sleep 0.2
  systemctl --user restart mako.service 2>/dev/null || true
fi
systemctl --user reset-failed mako.service 2>/dev/null || true

notify-send "Theme changed" "Switched to: $THEME" || true
echo "✓ Theme switched to $THEME"
