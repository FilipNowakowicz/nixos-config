{ pkgs, ... }:
{
  imports = [
    ../../profiles/agent-desktop.nix
    ../../profiles/agent-skills.nix
    ../../profiles/agent-usage.nix
    ../../profiles/calendar.nix
    ../../profiles/on-worker.nix
    ../../profiles/ntfy-notifications.nix
    ../../profiles/phone.nix
    ../../profiles/phone-backup.nix
    ../../profiles/python-development.nix
  ];

  # This user's phone and secrets for the presets imported above.
  fleet = {
    phoneBackup = {
      # KDE Connect's ID for the paired Galaxy S24 (`kdeconnect-cli -l`).
      deviceId = "f25cc0f05fce482c9e7b48507c116e17";
      snapshotHost = "galaxy-s24";
      sopsFile = ./secrets/phone-backup.yaml;
    };
    calendar.sopsFile = ./secrets/calendar-feeds.yaml;
    ntfy.sopsFile = ./secrets/ntfy.yaml;
  };

  workflowPacks = {
    browsing.enable = true;
    coding.enable = true;
    latex.enable = true;
    learning.enable = true;
  };

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
