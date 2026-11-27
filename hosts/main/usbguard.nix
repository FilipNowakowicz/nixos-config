# USB device allowlist: every device is blocked unless listed here.
_: {
  services.usbguard = {
    enable = true;
    IPCAllowedUsers = [
      "root"
      "user"
    ];
    rules = ''
      # Default policy: block all USB devices
      # Devices must be explicitly whitelisted below

      # Allow Logitech USB Receiver (mouse) — exact HID interface set only (guard against BadUSB spoofing)
      # ID: 046d:c54d
      allow id 046d:c54d serial "3081376B3335" name "USB Receiver" with-interface equals { 03:01:02 03:01:01 03:00:00 }

      # Allow Huawei EarPods (USB-C headphones) — exact interface set only:
      # audio control + 4 audio streaming + HID for the inline remote buttons.
      # ID: 12d1:3a06
      allow id 12d1:3a06 name "EarPods" with-interface equals { 01:01:00 01:02:00 01:02:00 01:02:00 01:02:00 03:00:00 }

      # Allow Intel CNVi Bluetooth (internal, Comet Lake AX201)
      # ID: 8087:0026
      allow id 8087:0026

      # Allow internal fingerprint reader (Synaptics Tudor; synaTudor drives it)
      # ID: 06cb:00be
      allow id 06cb:00be

      # Allow GenesysLogic USB extender hub (USB 2.1 + USB 3.1 interfaces)
      # ID: 05e3:0610, 05e3:0626
      allow id 05e3:0610
      allow id 05e3:0626

      # Allow GenesysLogic hubs inside the DisplayLink dock chain.
      # The dock nests hubs; 0620 (USB3.1) and 0608 (USB2.0) sit between the
      # allowed 0610 hub and the DisplayLink video chip. Without these the
      # inner hubs are deauthorized and everything downstream (DisplayLink,
      # dock NIC) never enumerates. No serial exposed (SerialNumber=0), so
      # matched by id like the sibling hubs above. See .claude/main/displaylink.md.
      # ID: 05e3:0620, 05e3:0608
      allow id 05e3:0620
      allow id 05e3:0608

      # Allow DisplayLink video/NIC/audio device in the Dell Universal Dock D6000
      # used for the external monitor. Serial captured from kernel history on
      # 2026-06-05 after the dock enumerated with USBGuard disabled.
      # ID: 17e9:6006, serial: 1712026441
      allow id 17e9:6006 serial "1712026441" name "Dell Universal Dock D6000"

      # Allow integrated webcam (SunplusIT)
      # ID: 13d3:56b2
      allow id 13d3:56b2

      # Allow SanDisk Ultra USB backup stick
      # ID: 0781:5581, serial: 4C530001250727100272
      allow id 0781:5581 serial "4C530001250727100272" name "Ultra"

      # Allow Toshiba TransMemory USB installer stick
      # ID: 0930:6544, serial: C412F52D6C79C2307002C73F
      allow id 0930:6544 serial "C412F52D6C79C2307002C73F" name "TransMemory"

      # Reject everything else
      reject
    '';
  };
}
