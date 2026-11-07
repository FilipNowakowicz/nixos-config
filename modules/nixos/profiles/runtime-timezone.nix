# A timezone chosen at runtime (`timedatectl set-timezone`, e.g. from the
# shell's Spotlight) instead of pinned in Nix, that survives an ephemeral root.
#
# With `time.timeZone = null` NixOS leaves /etc/localtime to systemd-timedated,
# but a rolled-back root starts every boot without it, which means UTC. So the
# chosen zone's name is saved to a persistent file whenever /etc/localtime
# changes, and restored early in boot. Night light and weather in the shell
# follow /etc/localtime, so they move with it.
{ config, lib, ... }:
let
  cfg = config.profiles.runtimeTimezone;
  zoneinfo = "/etc/zoneinfo";
in
{
  options.profiles.runtimeTimezone = {
    enable = lib.mkEnableOption "a timezone set at runtime and kept across reboots";
    default = lib.mkOption {
      type = lib.types.str;
      example = "Europe/London";
      description = "Zone used until one is chosen, or if the saved one no longer exists.";
    };
    stateFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/runtime-timezone/zone";
      description = "Where the chosen zone's name is kept. Must be on persistent storage.";
    };
  };

  config = lib.mkIf cfg.enable {
    time.timeZone = null;

    systemd = {
      services.restore-timezone = {
        description = "Restore the chosen timezone";
        # Before anything reads the local time; also started by the first
        # switch, which drops the /etc/localtime NixOS used to manage.
        wantedBy = [
          "sysinit.target"
          "multi-user.target"
        ];
        before = [
          "sysinit.target"
          "time-set.target"
        ];
        after = [ "local-fs.target" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig.Type = "oneshot";
        script = ''
          zone=$(cat ${lib.escapeShellArg cfg.stateFile} 2>/dev/null || true)
          if [ -z "$zone" ] || [ ! -f "${zoneinfo}/$zone" ]; then
            zone=${lib.escapeShellArg cfg.default}
          fi
          ln -sfn "${zoneinfo}/$zone" /etc/localtime
        '';
      };

      # timedated replaces the /etc/localtime symlink with a rename. A path unit
      # on the symlink would watch the zone file it points at instead, so watch
      # /etc itself; it rarely changes, and the save only writes on a new zone.
      paths.save-timezone = {
        wantedBy = [ "multi-user.target" ];
        pathConfig.PathChanged = "/etc";
      };
      services.save-timezone = {
        description = "Keep the chosen timezone across reboots";
        serviceConfig.Type = "oneshot";
        script = ''
          target=$(readlink /etc/localtime) || exit 0
          zone=''${target#*zoneinfo/}
          [ -f "${zoneinfo}/$zone" ] || exit 0
          [ "$(cat ${lib.escapeShellArg cfg.stateFile} 2>/dev/null)" = "$zone" ] && exit 0
          mkdir -p "$(dirname ${lib.escapeShellArg cfg.stateFile})"
          printf '%s\n' "$zone" > ${lib.escapeShellArg cfg.stateFile}.new
          mv ${lib.escapeShellArg cfg.stateFile}.new ${lib.escapeShellArg cfg.stateFile}
        '';
      };
    };
  };
}
