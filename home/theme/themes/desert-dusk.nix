# Desert Dusk — warm gruvbox-inspired palette
# Values are plain hex without '#' — prepend '#' for CSS, use directly in rgb() for Hyprland.
{
  name = "desert-dusk";
  enabled = true;

  # Neovim colorscheme. gruvbox-material is the only loaded scheme; this warm
  # palette is its most natural fit.
  colorscheme = {
    name = "gruvbox-material";
    background = "dark";
    contrast = "medium";
  };

  colors = {
    bg = "1c1a18"; # dark background
    surface = "4a3728"; # mid brown
    secondary = "9b5d22"; # toned warm orange accent
    accent = "c77a24"; # softer amber highlight
    text = "f0d0a0"; # cream text
  };

  # 16-slot ANSI palette tuned to the warm desert / gruvbox palette.
  ansiColors = {
    color0 = "1c1a18"; # bg (black)
    color8 = "4a3728"; # surface (bright black)
    color1 = "cc4a3a"; # red
    color9 = "e26450"; # bright red
    color2 = "a08a2e"; # green (olive)
    color10 = "c2a83f"; # bright green
    color3 = "c77a24"; # yellow (accent)
    color11 = "e09b3c"; # bright yellow
    color4 = "7a8a5e"; # blue (muted khaki-blue)
    color12 = "97a878"; # bright blue
    color5 = "b06a4a"; # magenta (warm)
    color13 = "cc8560"; # bright magenta
    color6 = "9b8a4a"; # cyan (gold-toned)
    color14 = "bba85e"; # bright cyan
    color7 = "f0d0a0"; # text (white/cream)
    color15 = "fae3bf"; # bright white
  };

  wallpaper = ../wallpapers/desert-dusk.png;
}
