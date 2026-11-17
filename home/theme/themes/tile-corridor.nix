# Tile Corridor — a dark hallway under ceiling lamps; warm light on grey tile
# Values are plain hex without '#' — prepend '#' for CSS, use directly in rgb() for Hyprland.
{
  name = "tile-corridor";
  displayName = "Tile Corridor";
  enabled = true;

  # Dark or light: GTK, Firefox and Neovim follow it.
  appearance = "dark";

  colors = {
    bg = "0e0d0c"; # shadowed walls
    surface = "1e1c1a"; # tile in shade
    secondary = "7a7570"; # the street beyond
    accent = "e6d8bc"; # the ceiling lamps, slightly warm
    text = "e8e4de";
  };

  # 16-slot ANSI palette: neutral greys warmed toward lamplight.
  ansiColors = {
    color0 = "0e0d0c"; # bg (black)
    color8 = "34302c"; # surface, lifted (bright black)
    color1 = "b08a7e"; # red (brick)
    color9 = "cca698"; # bright red
    color2 = "9a9c80"; # green (moss)
    color10 = "b6b89a"; # bright green
    color3 = "c4ae86"; # yellow (lamp)
    color11 = "e0caa0"; # bright yellow
    color4 = "8a94a0"; # blue (daylight)
    color12 = "a6b0bc"; # bright blue
    color5 = "a8909a"; # magenta (faded)
    color13 = "c4acb6"; # bright magenta
    color6 = "8ea09a"; # cyan (glass)
    color14 = "aabcb6"; # bright cyan
    color7 = "e8e4de"; # text (white)
    color15 = "f8f5f0"; # bright white
  };

  wallpaper = ../wallpapers/tile-corridor.jpg;
}
