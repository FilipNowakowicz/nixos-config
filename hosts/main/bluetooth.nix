# Intel CNVi Bluetooth: delayed driver load, forced power-on, and the
# hardening the daemon needs. The shell owns the Bluetooth UI.
{ pkgs, ... }:
{
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # Loaded later by bluetooth-load-btusb; see below.
  boot.blacklistedKernelModules = [ "btusb" ];

  services = {
    # Bluetooth management (GUI)
    blueman.enable = true;

    # bluetoothd: needs AF_BLUETOOTH + AF_NETLINK for HCI management.
    # Skip PrivateDevices (/dev/hci*), ProtectKernelModules (hci module loading).
    hardened.bluetooth = {
      relaxBase = [
        "PrivateDevices"
        "ProtectKernelModules"
      ];
      extraConfig = {
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_BLUETOOTH"
          "AF_NETLINK"
        ];
      };
    };
  };

  systemd = {
    # The shell owns Bluetooth status and control, so suppress the redundant
    # Blueman tray icon instead of autostarting blueman-applet.
    user.services.blueman-applet.enable = false;

    services = {
      # This Intel CNVi adapter occasionally fails firmware download if btusb
      # probes as soon as udev sees the USB device:
      #
      #   Bluetooth: hci0: Failed to send firmware data (-38)
      #   usb 1-14: device descriptor read/64, error -71
      #
      # Keep btusb blacklisted above and load it here after early boot settles.
      # The timer below starts this at boot: bluetooth.target only follows the
      # hci0 device, which cannot exist until btusb is loaded, so otherwise
      # Bluetooth stays off until something happens to activate org.bluez.
      bluetooth-load-btusb = {
        description = "Load Intel Bluetooth USB driver after early boot settles";
        requiredBy = [ "bluetooth.service" ];
        before = [ "bluetooth.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${pkgs.kmod}/bin/modprobe btusb
        '';
      };

      # Policy.AutoEnable can still race the adapter's MGMT init after firmware
      # load (bluetoothd logs "Failed to set default system config for hci0" and
      # leaves hci0 powered off). Force it on via D-Bus once the /org/bluez/hci0
      # object is exposed. bluetoothctl is unusable here: in non-interactive
      # mode it silently no-ops and exits 0 regardless of state.
      bluetooth-power-on = {
        description = "Power on Bluetooth controller after bluez is ready";
        wantedBy = [ "bluetooth.target" ];
        after = [ "bluetooth.service" ];
        bindsTo = [ "bluetooth.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          for _ in $(seq 1 30); do
            if ${pkgs.systemd}/bin/busctl set-property \
                 org.bluez /org/bluez/hci0 \
                 org.bluez.Adapter1 Powered b true 2>/dev/null; then
              exit 0
            fi
            sleep 1
          done
          echo "Timed out waiting for /org/bluez/hci0" >&2
          exit 1
        '';
      };
    };

    # A timer rather than multi-user.target, so the delay never holds up boot.
    timers.bluetooth-load-btusb = {
      description = "Load Intel Bluetooth USB driver after early boot settles";
      wantedBy = [ "timers.target" ];
      timerConfig.OnActiveSec = "10s";
    };
  };
}
