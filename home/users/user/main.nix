{ pkgs, ... }:
{
  imports = [
    ../../profiles/calendar.nix
    ../../profiles/python-development.nix
  ];

  home.packages = with pkgs; [
    # This machine's dock and panel policy, called from hyprland.lua.
    (writeShellApplication {
      name = "hypr-display-mode";
      runtimeInputs = [
        gnugrep
        hyprland
        util-linux
      ];
      text = builtins.readFile ../../files/scripts/hypr-display-mode.sh;
    })

    galaxy-buds-client
    modrinth-app
  ];

  services.easyeffects = {
    enable = true;
    preset.input = "Buds-Soft-S-Low-Cut";
    extraPresets."Buds-Soft-S-Low-Cut" = builtins.fromJSON (
      builtins.readFile ../../files/easyeffects/Buds-Soft-S-Low-Cut.json
    );
    settings = {
      # Select Easy Effects Source explicitly in calling apps; leave playback
      # and unrelated recording streams on their normal devices.
      EffectsPipelines = {
        processAllInputs = false;
        processAllOutputs = false;
      };
      StreamInputs = {
        useDefaultInputDevice = false;
        # WirePlumber's stable source can activate the Bluetooth microphone
        # from music mode; the underlying hardware source only exists in HFP.
        inputDevice = "bluez_input.78:C1:1D:64:9E:23";
        listenToMic = false;
        listenToMicVolume = 0.2;
      };
      StreamOutputs.useDefaultOutputDevice = true;
    };
  };

}
