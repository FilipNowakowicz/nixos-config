# Lunar Peaks — icy monochrome over a near-black base
# Values are plain hex without '#' — prepend '#' for CSS, use directly in rgb() for Hyprland.
{
  name = "lunar-peaks";
  displayName = "Lunar Peaks";
  enabled = true;

  # Neovim colorscheme. gruvbox-material is the only loaded scheme; per-theme we
  # drive vim.o.background and the gruvbox contrast variant from here.
  colorscheme = {
    name = "gruvbox-material";
    background = "dark";
    contrast = "hard"; # icy near-black base
  };

  colors = {
    bg = "0b0d0e";
    surface = "151718";
    secondary = "a6a6a6";
    accent = "d8d8d8";
    text = "eeeeee";
  };

  # 16-slot ANSI palette: icy monochrome grey-scale with faint cool tinting.
  ansiColors = {
    color0 = "0b0d0e"; # bg (black)
    color8 = "151718"; # surface (bright black)
    color1 = "9a8585"; # red (desaturated)
    color9 = "b89e9e"; # bright red
    color2 = "8a9a8a"; # green (desaturated)
    color10 = "a6b6a6"; # bright green
    color3 = "a6a695"; # yellow (desaturated)
    color11 = "c2c2b0"; # bright yellow
    color4 = "85909a"; # blue (cool grey)
    color12 = "a0acb6"; # bright blue
    color5 = "95909a"; # magenta (desaturated)
    color13 = "b0acb6"; # bright magenta
    color6 = "859a9a"; # cyan (icy)
    color14 = "a0b6b6"; # bright cyan
    color7 = "eeeeee"; # text (white)
    color15 = "ffffff"; # bright white
  };

  wallpaper = ../wallpapers/lunar-peaks.png;
}
