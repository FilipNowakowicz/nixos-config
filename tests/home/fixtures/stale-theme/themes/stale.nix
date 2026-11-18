# A theme still on the pre-rename palette keys (brown/orange/amber). The theme
# module must reject it by name instead of failing inside a template.
{
  name = "stale";
  # Dark or light: GTK, Firefox and Neovim follow it.
  appearance = "dark";
  colors = {
    bg = "000000";
    brown = "111111";
    orange = "222222";
    amber = "333333";
    text = "ffffff";
  };
  ansiColors = builtins.listToAttrs (
    map (i: {
      name = "color${toString i}";
      value = "444444";
    }) (builtins.genList (i: i) 16)
  );
  wallpaper = ./stale.nix;
}
