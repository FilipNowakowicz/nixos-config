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
    bg = "e3dbce"; # paper, toned down from white so it does not glare
    surface = "d3c8b6"; # shaded paper
    secondary = "8c7b62"; # index contours
    accent = "8f4626"; # burnt sienna, 5:1 on the paper
    text = "2b261f"; # ink
  };

  # 16-slot ANSI palette for a light background: every hue that is used as
  # text keeps at least 4.5:1 contrast on the paper, so "bright" stays dark.
  ansiColors = {
    color0 = "2b261f"; # ink (black)
    color8 = "62584c"; # pencil (bright black)
    color1 = "9e3b2a"; # red
    color9 = "a53f2b"; # bright red
    color2 = "4f5c22"; # green (olive)
    color10 = "556323"; # bright green
    color3 = "735210"; # yellow (ochre)
    color11 = "7a560c"; # bright yellow
    color4 = "35546d"; # blue (slate)
    color12 = "3b6280"; # bright blue
    color5 = "7a4463"; # magenta (plum)
    color13 = "864a6c"; # bright magenta
    color6 = "285e5a"; # cyan (teal)
    color14 = "2a6560"; # bright cyan
    color7 = "cfc5b5"; # light grey
    color15 = "f0eae0"; # white
  };

  wallpaper = ../wallpapers/paper-contours.jpg;
}
