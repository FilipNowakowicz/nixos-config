{
  config,
  lib,
  pkgs,
  ...
}:
# ── Logitech LIGHTSPEED receiver HID++ access (046d:c54d) ───────────────────
#
# The quiet shell asks the mouse for its battery over HID++, because no kernel
# driver claims this receiver. Grant the seat user that one interface (02,
# HID++) and not 01, which carries keystrokes. Parent-matching keys must all
# match a single parent, hence the two steps. 73-seat-late.rules applies
# uaccess, so this sorts before it, which services.udev.extraRules can't.
let
  rules = pkgs.writeTextDir "lib/udev/rules.d/70-logitech-hidpp.rules" ''
    SUBSYSTEM!="hidraw", GOTO="logitech_hidpp_end"
    KERNELS=="0003:046D:C54D.*", ENV{LOGITECH_HIDPP_RECEIVER}="1"
    ENV{LOGITECH_HIDPP_RECEIVER}=="1", ATTRS{bInterfaceNumber}=="02", TAG+="uaccess"
    LABEL="logitech_hidpp_end"
  '';
in
{
  options.hardware.logitechHidpp.enable = lib.mkEnableOption "seat-user HID++ access to the Logitech LIGHTSPEED receiver";

  config = lib.mkIf config.hardware.logitechHidpp.enable {
    services.udev.packages = [ rules ];
  };
}
