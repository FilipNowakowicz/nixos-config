# Cold Concrete — cool blue-grey with muted sand accents
# Values are plain hex without '#' — prepend '#' for CSS, use directly in rgb() for Hyprland.
{
  name = "cold-concrete";
  displayName = "Cold Concrete";
  enabled = true;

  # Dark or light: GTK, Firefox and Neovim follow it.
  appearance = "dark";

  colors = {
    bg = "06090d";
    surface = "111820";
    secondary = "d8d2b8";
    accent = "9bb8bd";
    text = "d7e1df";
  };

  # 16-slot ANSI palette tuned to the cool blue-grey / sand palette.
  ansiColors = {
    color0 = "06090d"; # bg (black)
    color8 = "111820"; # surface (bright black)
    color1 = "a36b6b"; # red
    color9 = "c08585"; # bright red
    color2 = "8ba383"; # green
    color10 = "a6bd9d"; # bright green
    color3 = "d8d2b8"; # yellow (sand accent)
    color11 = "e6e0c9"; # bright yellow
    color4 = "7d97a8"; # blue
    color12 = "9bb8bd"; # bright blue (cool accent)
    color5 = "9489a3"; # magenta
    color13 = "ada3ba"; # bright magenta
    color6 = "7fa6a8"; # cyan
    color14 = "9bbdbf"; # bright cyan
    color7 = "d7e1df"; # text (white)
    color15 = "eef3f2"; # bright white
  };

  wallpaper = ../wallpapers/cold-concrete.jpg;
}
