{
  config,
  lib,
  pkgs,
  ...
}:
# ── Synaptics Tudor fingerprint reader (06cb:00be) ──────────────────────────
#
# libfprint has no open driver for this sensor. fprintd runs it through the
# synaTudor TOD driver, whose host process lives outside fprintd's sandbox and
# is started on demand over D-Bus. Gated off in CI like displaylink.nix, so
# `main-ci` never builds the driver.
#
# PAM wiring (which login paths use the fingerprint) stays with the host.
let
  cfg = config.hardware.synapticsTudor;
  enable = cfg.enable && !config.profiles.ci;
  synatudor = pkgs.callPackage ../../../packages/synatudor { };
in
{
  options.hardware.synapticsTudor.enable = lib.mkEnableOption "the Synaptics Tudor fingerprint reader via fprintd and synaTudor";

  config = lib.mkIf enable {
    services = {
      fprintd = {
        enable = true;
        tod = {
          enable = true;
          driver = synatudor;
        };
      };
      dbus.packages = [ synatudor ];
      udev.packages = [ synatudor ];
    };

    systemd = {
      packages = [ synatudor ];

      # With no ordering between them, shutdown stopped the Tudor host first.
      # fprintd, in the middle of hyprlock's verify, then ignored SIGTERM for
      # the full 90s default timeout. Ordering it after the host makes
      # shutdown stop fprintd first. It keeps nothing in memory (enrollments
      # are written when they are made), so a short kill timeout covers any
      # other way it can hang.
      services.fprintd = {
        after = [ "tudor-host-launcher.service" ];
        serviceConfig.TimeoutStopSec = "5s";
      };
    };
  };
}
