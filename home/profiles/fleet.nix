{ lib, ... }:
{
  options.fleet = {
    hostName = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Fleet host name used by user-level commands.";
    };

    quietShell = lib.mkEnableOption "the Quickshell desktop shell in place of Waybar, the GTK control centre, the launcher and mako";

    skipHeavyPackages = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Skip heavyweight interactive packages for CI and lean profiles.";
    };

    enableSpotify = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install Spotify where the desktop package set is enabled.";
    };
  };
}
