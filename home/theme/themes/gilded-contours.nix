# Gilded Contours — deep navy with warm metallic highlights
# Values are plain hex without '#' — prepend '#' for CSS, use directly in rgb() for Hyprland.
{
  name = "gilded-contours";
  displayName = "Gilded Contours";
  enabled = true;

  # Neovim colorscheme. gruvbox-material is the only loaded scheme; per-theme we
  # drive vim.o.background and the gruvbox contrast variant from here.
  colorscheme = {
    name = "gruvbox-material";
    background = "dark";
    contrast = "hard"; # deep navy base
  };

  colors = {
    bg = "071126";
    surface = "0d1830";
    secondary = "e0c290";
    accent = "d3ad7a";
    text = "f0d5a2";
  };

  # 16-slot ANSI palette tuned to the deep-navy / metallic-gold palette.
  ansiColors = {
    color0 = "071126"; # bg (black)
    color8 = "0d1830"; # surface (bright black)
    color1 = "c0614f"; # red
    color9 = "d87a66"; # bright red
    color2 = "9aa86a"; # green
    color10 = "b6c485"; # bright green
    color3 = "d3ad7a"; # yellow (accent)
    color11 = "e0c290"; # bright yellow (gold)
    color4 = "5a78a8"; # blue
    color12 = "7895c2"; # bright blue
    color5 = "9a7aa8"; # magenta
    color13 = "b695c2"; # bright magenta
    color6 = "6a98a8"; # cyan
    color14 = "85b6c4"; # bright cyan
    color7 = "f0d5a2"; # text (white/cream)
    color15 = "f8e6c4"; # bright white
  };

  wallpaper = ../wallpapers/gilded-contours.jpg;
}
