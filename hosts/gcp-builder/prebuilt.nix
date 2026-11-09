{ pkgs, ... }:
let
  prebuild = pkgs.writeShellApplication {
    name = "builder-prebuild";
    runtimeInputs = with pkgs; [
      nix
      jq
      coreutils
      curl
    ];
    text = builtins.readFile ../../scripts/builder-prebuild.sh;
  };
in
{
  # Runs only from the timer, so an ordinary on-demand boot does not start a full
  # `main` build alongside the job that woke the VM.
  systemd.services.builder-prebuild = {
    description = "Prebuild latest public main system for the workstation";
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "nix-daemon.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "user";
      StateDirectory = "builder-prebuilt";
      StateDirectoryMode = "0755";
      ExecStart = "${prebuild}/bin/builder-prebuild";
      ExecStopPost = "${prebuild}/bin/builder-prebuild --service-failed";
      TimeoutStartSec = "3h";
      TimeoutStopSec = "30s";
      KillMode = "control-group";
    };
  };

  # GCE starts the VM within 15 minutes of 20:00 UTC, and the idle shutdown allows
  # 20 minutes after boot, so this fires once the VM is up and before it powers off.
  systemd.timers.builder-prebuild = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "Fri *-*-* 20:17:00 UTC";
  };
}
