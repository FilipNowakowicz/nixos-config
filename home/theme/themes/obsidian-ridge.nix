# Obsidian Ridge — soft greys on charcoal
# Values are plain hex without '#' — prepend '#' for CSS, use directly in rgb() for Hyprland.
{
  name = "obsidian-ridge";
  displayName = "Obsidian Ridge";
  enabled = true;

  # Dark or light: GTK, Firefox and Neovim follow it.
  appearance = "dark";

  colors = {
    bg = "111111";
    surface = "1d1d1d";
    secondary = "5f5f5f";
    accent = "8f8f8f";
    text = "d0d0d0";
  };

  # 16-slot ANSI palette: soft monochrome grey-scale on charcoal.
  ansiColors = {
    color0 = "111111"; # bg (black)
    color8 = "1d1d1d"; # surface (bright black)
    color1 = "7a6a6a"; # red (desaturated)
    color9 = "968282"; # bright red
    color2 = "6a7a6a"; # green (desaturated)
    color10 = "829682"; # bright green
    color3 = "8f8f7a"; # yellow (desaturated)
    color11 = "aaaa96"; # bright yellow
    color4 = "6a6a7a"; # blue (desaturated)
    color12 = "828296"; # bright blue
    color5 = "7a6a7a"; # magenta (desaturated)
    color13 = "968296"; # bright magenta
    color6 = "6a7a7a"; # cyan (desaturated)
    color14 = "829696"; # bright cyan
    color7 = "d0d0d0"; # text (white)
    color15 = "f0f0f0"; # bright white
  };

  wallpaper = ../wallpapers/obsidian-ridge.jpg;
}
