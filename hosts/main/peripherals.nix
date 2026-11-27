# Built-in fingerprint reader and the Logitech LIGHTSPEED receiver.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  synatudor = pkgs.callPackage ../../packages/synatudor { };
  # The quiet shell asks the mouse for its battery over HID++, because no kernel
  # driver claims this LIGHTSPEED receiver (046d:c54d). Grant the seat user that
  # one interface (02, HID++) and not 01, which carries keystrokes. Parent-matching
  # keys must all match a single parent, hence the two steps. 73-seat-late.rules
  # applies uaccess, so this sorts before it, which services.udev.extraRules can't.
  logitechHidpp = pkgs.writeTextDir "lib/udev/rules.d/70-logitech-hidpp.rules" ''
    SUBSYSTEM!="hidraw", GOTO="logitech_hidpp_end"
    KERNELS=="0003:046D:C54D.*", ENV{LOGITECH_HIDPP_RECEIVER}="1"
    ENV{LOGITECH_HIDPP_RECEIVER}=="1", ATTRS{bInterfaceNumber}=="02", TAG+="uaccess"
    LABEL="logitech_hidpp_end"
  '';
in
{
  services = {
    fprintd = lib.mkIf (!config.profiles.ci) {
      enable = true;
      tod = {
        enable = true;
        driver = synatudor;
      };
    };

    # The driver's host process runs outside fprintd's sandbox, started on demand over D-Bus.
    dbus.packages = lib.mkIf (!config.profiles.ci) [ synatudor ];
    udev.packages = [ logitechHidpp ] ++ lib.optional (!config.profiles.ci) synatudor;
  };

  systemd = {
    packages = lib.mkIf (!config.profiles.ci) [ synatudor ];

    # fprintd drives the sensor through the Tudor host process. With no ordering
    # between them, shutdown stopped the host first. fprintd, in the middle of
    # hyprlock's verify, then ignored SIGTERM for the full 90s default timeout.
    # Ordering it after the host makes shutdown stop fprintd first. It keeps
    # nothing in memory (enrollments are written when they are made), so a
    # short kill timeout covers any other way it can hang.
    services.fprintd = lib.mkIf (!config.profiles.ci) {
      after = [ "tudor-host-launcher.service" ];
      serviceConfig.TimeoutStopSec = "5s";
    };
  };

  security.pam.services = lib.mkIf (!config.profiles.ci) {
    # hyprlock reads the fingerprint itself, so a password works at the same time.
    # Through PAM it would have to wait for the fingerprint attempt to end.
    hyprlock.fprintAuth = false;
    greetd.fprintAuth = true;
  };
}
