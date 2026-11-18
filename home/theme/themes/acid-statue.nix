# Acid Statue — blue-grey with acid green highlights
# Values are plain hex without '#' — prepend '#' for CSS, use directly in rgb() for Hyprland.
{
  name = "acid-statue";
  displayName = "Acid Statue";
  enabled = true;

  # Dark or light: GTK, Firefox and Neovim follow it.
  appearance = "dark";

  colors = {
    bg = "1e2330"; # dark blue-grey background
    surface = "2e3a4a"; # muted slate surface
    secondary = "43675d"; # more muted teal accent
    accent = "7ea63f"; # toned moss-green highlight
    text = "c8d4c0"; # cool off-white text
  };

  # 16-slot ANSI palette tuned to the acid-green / blue-grey palette.
  ansiColors = {
    color0 = "1e2330"; # bg (black)
    color8 = "2e3a4a"; # surface (bright black)
    color1 = "b05545"; # red
    color9 = "d06d5a"; # bright red
    color2 = "7ea63f"; # green (acid highlight)
    color10 = "9bc456"; # bright green
    color3 = "b0a04a"; # yellow
    color11 = "c9bb63"; # bright yellow
    color4 = "5b7f9a"; # blue
    color12 = "7398b3"; # bright blue
    color5 = "8a6f9a"; # magenta
    color13 = "a589b3"; # bright magenta
    color6 = "43675d"; # cyan (teal accent)
    color14 = "5d8478"; # bright cyan
    color7 = "c8d4c0"; # text (white)
    color15 = "e2ebda"; # bright white
  };

  wallpaper = ../wallpapers/acid-statue.png;
}
