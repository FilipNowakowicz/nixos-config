#!/bin/bash
set -euo pipefail

THEME="${1:-}"
THEMES_DIR="$HOME/.config/themes"
REPO_THEMES_DIR="$NIX_REPO/home/theme/themes"
REPO_WALLPAPERS_DIR="$NIX_REPO/home/theme/wallpapers"
ACTIVE_FILE="$NIX_REPO/home/theme/active.nix"
LINKS_FILE="$THEMES_DIR/links.sh"

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
  echo "Theme '$THEME' is already active"
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

# Reload apps
hyprctl reload >/dev/null 2>&1 || true

pkill waybar || true
sleep 0.3
waybar &

old_swaybg_pids=()
while IFS= read -r pid; do
  [[ -n $pid ]] && old_swaybg_pids+=("$pid")
done < <(pgrep -x swaybg || true)
swaybg -m fill -i "$HOME/.local/share/wallpapers/current.png" &
sleep 0.2
if ((${#old_swaybg_pids[@]} > 0)); then
  kill "${old_swaybg_pids[@]}" 2>/dev/null || true
fi

for socket in /tmp/kitty-*/kitty-*; do
  [[ -S $socket ]] && kitty @ --to "unix:$socket" load-config 2>/dev/null || true
done

pkill mako || true
sleep 0.5
systemctl --user restart mako.service 2>/dev/null || true

notify-send "Theme changed" "Switched to: $THEME" || true
echo "✓ Theme switched to $THEME"
