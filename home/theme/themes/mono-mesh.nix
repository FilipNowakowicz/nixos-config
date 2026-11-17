# Monochrome Mesh — near black with grey accents
# Values are plain hex without '#' — prepend '#' for CSS, use directly in rgb() for Hyprland.
{
  name = "mono-mesh";
  enabled = true;

  # Neovim colorscheme. gruvbox-material is the only loaded scheme; per-theme we
  # drive vim.o.background and the gruvbox contrast variant from here.
  colorscheme = {
    name = "gruvbox-material";
    background = "dark";
    contrast = "hard"; # near-black base
  };

  colors = {
    bg = "0a0a0a"; # near black background
    surface = "2a2a2a"; # dark surface
    secondary = "888888"; # mid grey accent
    accent = "cccccc"; # light grey highlight
    text = "e8e8e8"; # near white text
  };

  # 16-slot ANSI palette: neutral monochrome grey-scale.
  ansiColors = {
    color0 = "0a0a0a"; # bg (black)
    color8 = "2a2a2a"; # surface (bright black)
    color1 = "8a8a8a"; # red (neutral grey)
    color9 = "a6a6a6"; # bright red
    color2 = "999999"; # green
    color10 = "b3b3b3"; # bright green
    color3 = "aaaaaa"; # yellow
    color11 = "c2c2c2"; # bright yellow
    color4 = "888888"; # blue (mid grey accent)
    color12 = "a0a0a0"; # bright blue
    color5 = "959595"; # magenta
    color13 = "b0b0b0"; # bright magenta
    color6 = "aaaaaa"; # cyan
    color14 = "c2c2c2"; # bright cyan
    color7 = "e8e8e8"; # text (white)
    color15 = "ffffff"; # bright white
  };

  wallpaper = ../wallpapers/mono-mesh.jpg;
}
