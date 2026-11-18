# Skyline Window — a hazy city seen from a dark room; cool steel greys
# Values are plain hex without '#' — prepend '#' for CSS, use directly in rgb() for Hyprland.
{
  name = "skyline-window";
  displayName = "Skyline Window";
  enabled = true;

  colorscheme = {
    name = "gruvbox-material";
    background = "dark";
    contrast = "hard"; # near-black room
  };

  colors = {
    bg = "0c0d0f"; # the unlit room
    surface = "1b1e22"; # window frame
    secondary = "6c7680"; # far towers in the haze
    accent = "aebdca"; # the bright, slightly blue sky
    text = "e2e6ea";
  };

  # 16-slot ANSI palette: steel greys with a faint cool cast.
  ansiColors = {
    color0 = "0c0d0f"; # bg (black)
    color8 = "2a2f35"; # surface, lifted (bright black)
    color1 = "a88a8c"; # red (dusty)
    color9 = "c4a4a6"; # bright red
    color2 = "8a9e92"; # green (grey-green)
    color10 = "a6baae"; # bright green
    color3 = "b0aa94"; # yellow (sodium haze)
    color11 = "ccc6ae"; # bright yellow
    color4 = "8296a8"; # blue (steel)
    color12 = "a0b4c6"; # bright blue
    color5 = "9a90a8"; # magenta (dusk)
    color13 = "b6acc4"; # bright magenta
    color6 = "84a2a8"; # cyan (glass)
    color14 = "a2bec4"; # bright cyan
    color7 = "e2e6ea"; # text (white)
    color15 = "f6f8fa"; # bright white
  };

  wallpaper = ../wallpapers/skyline-window.jpg;
}
