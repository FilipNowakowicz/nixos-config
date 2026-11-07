# Wayland UI components whose theme assets are regenerated and live-reloaded
# by theme-switch. The wallpaper is not here: the theme module runs swaybg as
# its own unit. Single source consumed by both the install list
# (home/profiles/desktop.nix `home.packages`) and the theme-switch runtime
# inputs (home/theme/module.nix), so the two lists can never drift.
{ pkgs }:
with pkgs;
[
  kitty
]
