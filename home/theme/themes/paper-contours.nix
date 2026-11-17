# Paper Contours — a topographic map on warm paper; the light theme
# Values are plain hex without '#' — prepend '#' for CSS, use directly in rgb() for Hyprland.
# The wallpaper is generated (ImageMagick contour lines over a plasma field),
# not a photo.
{
  name = "paper-contours";
  displayName = "Paper Contours";
  enabled = true;

  appearance = "light";

  colors = {
    bg = "f2ece2"; # paper
    surface = "e2d9ca"; # shaded paper
    secondary = "8c7b62"; # index contours
    accent = "9a4f2c"; # burnt sienna, 5:1 on the paper
    text = "2f2a24"; # ink
  };

  # 16-slot ANSI palette for a light background: every hue that is used as
  # text keeps at least 4.5:1 contrast on the paper, so "bright" stays dark.
  ansiColors = {
    color0 = "2f2a24"; # ink (black)
    color8 = "6e6457"; # pencil (bright black)
    color1 = "9e3b2a"; # red
    color9 = "b2452f"; # bright red
    color2 = "4f5c22"; # green (olive)
    color10 = "5f6d2b"; # bright green
    color3 = "735210"; # yellow (ochre)
    color11 = "85600f"; # bright yellow
    color4 = "35546d"; # blue (slate)
    color12 = "46708f"; # bright blue
    color5 = "7a4463"; # magenta (plum)
    color13 = "925277"; # bright magenta
    color6 = "285e5a"; # cyan (teal)
    color14 = "2f6e69"; # bright cyan
    color7 = "d8cfc0"; # light grey
    color15 = "f8f4ec"; # white
  };

  wallpaper = ../wallpapers/paper-contours.jpg;
}
