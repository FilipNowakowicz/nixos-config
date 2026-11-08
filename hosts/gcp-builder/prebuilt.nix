{ pkgs, ... }:
let
  prebuild = pkgs.writeShellApplication {
    name = "builder-prebuild";
    runtimeInputs = with pkgs; [
      nix
      jq
      coreutils
    ];
    text = builtins.readFile ../../scripts/builder-prebuild.sh;
  };
in
{
  # Every boot resolves public main; Friday's GCE schedule is the unattended trigger.
  systemd.services.builder-prebuild = {
    description = "Prebuild latest public main system for the workstation";
    wantedBy = [ "multi-user.target" ];
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
}
