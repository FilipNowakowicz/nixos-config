# Nighthawks — cold diner blue, slate and silver
# Values are plain hex without '#' — prepend '#' for CSS, use directly in rgb() for Hyprland.
{
  name = "nighthawks";
  displayName = "Nighthawks";
  enabled = true;

  # Neovim colorscheme. gruvbox-material is the only loaded scheme; per-theme we
  # drive vim.o.background and the gruvbox contrast variant from here.
  colorscheme = {
    name = "gruvbox-material";
    background = "dark";
    contrast = "medium";
  };

  colors = {
    bg = "161a20"; # near black blue-grey
    surface = "2a3040"; # dark slate surface
    secondary = "4a5568"; # muted blue-grey accent
    accent = "8aa4b8"; # cold silver-blue highlight
    text = "c8d0d8"; # cool light grey text
  };

  # 16-slot ANSI palette tuned to the cold slate / silver-blue palette.
  ansiColors = {
    color0 = "161a20"; # bg (black)
    color8 = "2a3040"; # surface (bright black)
    color1 = "a5616b"; # red (cool)
    color9 = "c27d87"; # bright red
    color2 = "7e9a85"; # green (cool)
    color10 = "9bb6a2"; # bright green
    color3 = "9a9a78"; # yellow (muted)
    color11 = "b6b695"; # bright yellow
    color4 = "5a78a0"; # blue
    color12 = "8aa4b8"; # bright blue (silver-blue accent)
    color5 = "8a7ea0"; # magenta
    color13 = "a69bb8"; # bright magenta
    color6 = "6a8a9a"; # cyan
    color14 = "85a6b6"; # bright cyan
    color7 = "c8d0d8"; # text (white)
    color15 = "e4eaf0"; # bright white
  };

  wallpaper = ../wallpapers/nighthawks.jpg;
}
