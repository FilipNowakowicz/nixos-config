# Thermal and power-profile daemons, lid and idle suspend, and battery metrics.
_: {
  services = {
    # The battery, on top of the collectors every host gets; servers have none.
    prometheus.exporters.node.enabledCollectors = [ "powersupplyclass" ];

    thermald.enable = true;
    power-profiles-daemon.enable = true;

    logind.settings.Login = {
      HandleLidSwitch = "suspend";
      IdleAction = "suspend";
      IdleActionSec = "15min";
    };

    hardened = {
      # thermald: Intel thermal daemon running in --adaptive mode.
      # Needs /sys writes for thermal zones and perf_event_open for RAPL energy
      # readings; upstream NixOS unit ships with no SystemCallFilter so relaxing
      # the baseline filter would leave it completely unfiltered without this
      # explicit replacement.
      thermald = {
        relaxBase = [ "PrivateDevices" ];
        extraConfig = {
          SystemCallFilter = [
            "@system-service"
            "perf_event_open"
          ];
          ProtectProc = "invisible";
          ProcSubset = "pid";
          RestrictAddressFamilies = [ "AF_UNIX" ];
        };
      };

      # power-profiles-daemon: upstream unit ships its own tighter filter:
      #   @system-service ~@resources ~@privileged
      # Relax SystemCallFilter here so our baseline @system-service is not
      # appended after those denials (which would re-allow @resources /
      # @privileged). The upstream filter is intentionally preserved as-is.
      power-profiles-daemon = {
        relaxBase = [
          "PrivateDevices"
          "SystemCallFilter"
          "ProtectKernelTunables" # needs /sys writes for energy_perf_bias (performance profile)
        ];
        extraConfig = {
          ProtectProc = "invisible";
          ProcSubset = "pid";
          RestrictAddressFamilies = [ "AF_UNIX" ];
        };
      };
    };
  };
}
