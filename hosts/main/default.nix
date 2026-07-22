{
  config,
  inputs,
  lib,
  pkgs,
  hostRegistry,
  ...
}:
let
  binaryCache = import ../../lib/binary-cache.nix;

  agentMaintenanceCommands = [
    # Verify and trigger post-reinstall backup/check jobs.
    "/run/current-system/sw/bin/systemctl start restic-backups-local.service"
    "/run/current-system/sw/bin/systemctl start restic-check-local.service"
    "/run/current-system/sw/bin/systemctl status restic-backups-local.service --no-pager"
    "/run/current-system/sw/bin/systemctl status restic-backups-local.timer --no-pager"
    "/run/current-system/sw/bin/systemctl status restic-check-local.service --no-pager"
    "/run/current-system/sw/bin/systemctl status restic-check-local.timer --no-pager"
    "/run/current-system/sw/bin/systemctl start btrbk-local.service"
    "/run/current-system/sw/bin/systemctl status btrbk-local.service --no-pager"
    "/run/current-system/sw/bin/systemctl status btrbk-local.timer --no-pager"

    # Clean stale boot entries and old system generations after rebuilds.
    "/run/current-system/sw/bin/bootctl status --no-pager"
    "/run/current-system/sw/bin/bootctl cleanup"
    "/run/current-system/sw/bin/efibootmgr -b [0-9A-F][0-9A-F][0-9A-F][0-9A-F] -B"
    "/run/current-system/sw/bin/nix-gc-14d"

    # Root-equivalent activation path for agent-assisted local rebuilds.
    # Keep this scoped to the fixed-argument wrapper below rather than granting
    # broad passwordless sudo or arbitrary nh/nixos-rebuild commands.
    "/run/current-system/sw/bin/nixos-switch-main"
  ];

  passwordlessAgentCommand = command: {
    inherit command;
    options = [ "NOPASSWD" ];
  };

  # nh >= 4.3 added a hard "don't run nh as root" guard, which broke this
  # NOPASSWD wrapper: it is invoked as root via `sudo nixos-switch-main`, and nh
  # then refuses. Build and activate the closure directly instead — the same
  # manual pattern used for homeserver-gcp (nix build toplevel +
  # switch-to-configuration), so the passwordless agent-rebuild path keeps
  # working without granting broad NOPASSWD or running nh as root.
  nixosSwitchMain = pkgs.writeShellScriptBin "nixos-switch-main" ''
    set -euo pipefail
    flake=/home/user/nix
    # Root building a user-owned checkout otherwise trips git's dubious-ownership
    # guard; scope the exception to this flake path only.
    export HOME=/root
    ${pkgs.git}/bin/git config --global --add safe.directory "$flake" || true
    toplevel=$(${pkgs.nix}/bin/nix build --no-link --print-out-paths \
      "$flake#nixosConfigurations.main.config.system.build.toplevel")
    ${pkgs.nix}/bin/nix-env -p /nix/var/nix/profiles/system --set "$toplevel"
    exec "$toplevel/bin/switch-to-configuration" switch
  '';

  nixGc14d = pkgs.writeShellScriptBin "nix-gc-14d" ''
    exec ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 14d
  '';
in
{
  imports = [
    inputs.disko.nixosModules.disko
    inputs.lanzaboote.nixosModules.lanzaboote
    inputs.nix-index-database.nixosModules.default
    ./anonymous.nix
    ./backups.nix
    ./disko.nix
    ./impermanence.nix
    ./hardware-configuration.nix
    ./networking.nix
    ./nix-remote-build.nix
    ../../modules/nixos/profiles/base.nix
    ../../modules/nixos/profiles/desktop.nix
    ../../modules/nixos/profiles/observability-client.nix
    ../../modules/nixos/profiles/security.nix
    ../../modules/nixos/profiles/sops-base.nix
    ../../modules/nixos/profiles/user.nix
    ../../modules/nixos/hardware/nvidia-prime.nix
    ../../modules/nixos/hardware/displaylink.nix
  ];

  # ── Hardware ────────────────────────────────────────────────────────────────
  networking.hostName = "main";

  hardware = {
    bluetooth = {
      enable = true;
      powerOnBoot = true;
    };
    acpilight.enable = true;
  };

  system.stateVersion = "24.11";

  # time.timeZone = "Europe/London"; # switch back when back in London

  profiles = {
    # deploy-rs passes store settings for remote builds; trust the local admin
    # user so the daemon accepts those restricted options without warning.
    nix.extraTrustedUsers = [ "user" ];

    observability-client = {
      enable = true;
      remoteEndpoint.host = hostRegistry.homeserver-gcp.tailnetFQDN;
      ingestAuth = {
        passwordFile = config.sops.secrets.observability_ingest_password.path;
        serviceEnvironmentFile = config.sops.templates."otel-env".path;
      };
    };
    observability.collectors.metrics.scrapeInterval = "60s";
  };

  nix.settings = {
    extra-substituters = [ binaryCache.r2.substituter ];
    # Keep this in sync with the CI signing key used for the R2 binary cache;
    # see lib/binary-cache.nix for the rotation procedure.
    extra-trusted-public-keys = [ binaryCache.r2.publicKey ];
  };

  programs = {
    nix-index-database.comma.enable = true;
    virt-manager.enable = true;
    nix-ld.enable = true;
  };

  virtualisation.libvirtd.enable = true;

  systemd.services = {
    libvirtd-config.postStart = ''
      cat > /var/lib/libvirt/secret.conf <<'EOF'
      encrypt_data = 0
      EOF
    '';

    libvirtd = {
      unitConfig = {
        Requires = lib.mkForce [
          ""
          "libvirtd-config.service"
        ];
        After = lib.mkForce [
          ""
          "libvirtd.socket"
          "libvirtd-ro.socket"
          "libvirtd-admin.socket"
          "libvirtd-config.service"
          "virtlogd.socket"
          "virtlockd.socket"
          "network.target"
          "dbus.service"
          "apparmor.service"
          "remote-fs.target"
          "systemd-machined.service"
        ];
      };
      serviceConfig = {
        Environment = lib.mkForce [
          "SECRETS_ENCRYPTION_KEY="
        ];
        LoadCredentialEncrypted = lib.mkForce [ "" ];
      };
    };

    virtsecretd = {
      unitConfig = {
        Requires = lib.mkForce [ "" ];
        After = lib.mkForce [
          ""
          "virtsecretd.socket"
          "virtsecretd-ro.socket"
          "virtsecretd-admin.socket"
        ];
      };
      serviceConfig = {
        Environment = lib.mkForce [
          "SECRETS_ENCRYPTION_KEY="
        ];
        LoadCredentialEncrypted = lib.mkForce [ "" ];
      };
    };

    virt-secret-init-encryption = {
      serviceConfig = {
        ExecStart = lib.mkForce [
          ""
          "${pkgs.coreutils}/bin/true"
        ];
      };
    };
  };

  environment.systemPackages = with pkgs; [
    efibootmgr
    nh
    nixGc14d
    nixosSwitchMain
    sbctl
    spice-gtk
    swtpm
    virt-viewer
  ];

  # Narrow passwordless sudo for interactive agent-assisted maintenance.
  # Keep wheel passworded globally; only these exact commands are exempt.
  security = {
    sudo.extraConfig = ''
      Defaults lecture=never
    '';
    sudo.extraRules = [
      {
        users = [ "user" ];
        commands = map passwordlessAgentCommand agentMaintenanceCommands;
      }
    ];
    pam.services = lib.mkIf (!config.profiles.ci) {
      hyprlock.fprintAuth = true;
      greetd.fprintAuth = true;
    };
  };

  boot = {
    # Lanzaboote (Secure Boot)
    loader.systemd-boot.enable = lib.mkForce false;
    loader.systemd-boot.configurationLimit = 5;
    lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
    };

    # IOMMU protection — blocks Thunderbolt/PCIe DMA attacks
    kernelParams = [
      "intel_iommu=on"
      "iommu=force"
      "mem_sleep_default=deep"
    ];
    blacklistedKernelModules = [ "btusb" ];

    initrd = {
      # Systemd in initrd (required for initrd SSH)
      systemd = {
        enable = true;
        # Tear down all non-loopback interfaces before transitioning to stage 2.
        # Ensures port 2222 stops being reachable the moment stage 1 is done,
        # before stage 2's firewall loads. Guards against future misconfiguration
        # (e.g. if WiFi support were added to initrd later).
        services.flush-network-before-stage2 = {
          description = "Tear down initrd network before transitioning to stage 2";
          before = [ "initrd-cleanup.service" ];
          wantedBy = [ "initrd.target" ];
          unitConfig.DefaultDependencies = false;
          serviceConfig = {
            Type = "oneshot";
          };
          script = ''
            for iface in /sys/class/net/*; do
              iface=$(basename "$iface")
              [ "$iface" = "lo" ] && continue
              ${pkgs.iproute2}/bin/ip link set dev "$iface" down 2>/dev/null || true
              ${pkgs.iproute2}/bin/ip addr flush dev "$iface" 2>/dev/null || true
            done
          '';
        };
      };

      # Initrd SSH — fallback LUKS unlock when TPM2 fails.
      # Recovery requires a USB Ethernet dongle; WiFi is not available in stage 1.
      # Port 2222 is therefore NOT exposed on WiFi (including public WiFi).
      # flush-network-before-stage2 tears down the interface before stage 2 starts.
      network = {
        enable = true;
        ssh = {
          enable = true;
          port = 2222;
          authorizedKeys = import ../../lib/recovery-pubkeys.nix;
          hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
        };
      };
      secrets = {
        "/etc/secrets/initrd/ssh_host_ed25519_key" = lib.mkForce "/run/secrets/initrd_ssh_host_ed25519_key";
      };
    };
  };

  # ── Services ────────────────────────────────────────────────────────────────
  services = {
    sunshine = {
      enable = true;
      # Paused while mac-companion work is on hold (docs/goals/macbook-goals.md).
      # Note: the systemd.user.services.sunshine.wantedBy override below uses
      # mkForce, which wins over this module's own `mkIf cfg.autoStart [...]`
      # regardless of this flag — it must stay in sync with autoStart or this
      # setting is a no-op.
      autoStart = false;
      capSysAdmin = true;
      openFirewall = false;
    };

    thermald.enable = true;
    power-profiles-daemon.enable = true;
    fwupd.enable = true;
    btrfs.autoScrub = {
      enable = true;
      fileSystems = [ "/" ];
    };

    openssh = {
      enable = true;
      openFirewall = false; # Accessible via Tailscale only
      hostKeys = [
        {
          path = "/etc/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
      ];
    };

    logind.settings.Login = {
      HandleLidSwitch = "suspend";
      IdleAction = "suspend";
      IdleActionSec = "15min";
    };

    fprintd = lib.mkIf (!config.profiles.ci) {
      enable = true;
      tod = {
        enable = true;
        driver = pkgs.libfprint-2-tod1-goodix;
      };
    };
    # Bluetooth management (GUI)
    blueman.enable = true;

    # ── Systemd Failure Notifications ────────────────────────────────────────
    systemd-failure-notify = {
      enable = true;
      services = [
        # "prometheus"
        # "opentelemetry-collector"
        "btrbk-local"
        "restic-backups-local"
        "restic-check-local"
        "thermald"
        "power-profiles-daemon"
      ];
    };

  };

  services.hardened = {
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

    # fwupd: writes firmware to hardware and loads kernel modules.
    # Skip ProtectSystem (firmware writes), PrivateDevices (/dev access),
    # ProtectKernelModules/Tunables (capsule loading), ProtectClock (EFI time),
    # MemoryDenyWriteExecute (plugin loading).
    # Relaxing SystemCallFilter preserves fwupd's upstream custom allowlist
    # (@basic-io @file-system @io-event ... ioctl uname fadvise64 ...), which
    # is narrower than @system-service; appending @system-service would widen
    # it.
    fwupd = {
      relaxBase = [
        "PrivateDevices"
        "ProtectSystem"
        "ProtectKernelTunables"
        "ProtectKernelModules"
        "ProtectClock"
        "MemoryDenyWriteExecute"
        "SystemCallFilter"
        "ProcSubset"
      ];
      extraConfig = {
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        # fwupd 2.1.4 added fwupd-refresh.service, which runs as a dedicated
        # fwupd-refresh user with StateDirectory=fwupd. systemd therefore chowns
        # /var/lib/fwupd to fwupd-refresh:fwupd-refresh (0755). The root-run
        # fwupd.service daemon then needs CAP_DAC_OVERRIDE to write into a
        # directory it no longer owns, plus CAP_CHOWN/CAP_FOWNER to set
        # ownership/permissions on the keyring/pki files it creates there. The
        # hardening baseline strips all capabilities by default, so re-grant
        # exactly these three (otherwise fwupd.service fails -> SystemdUnitFailed).
        CapabilityBoundingSet = [
          "CAP_DAC_OVERRIDE"
          "CAP_CHOWN"
          "CAP_FOWNER"
        ];
      };
    };

    # bluetoothd: needs AF_BLUETOOTH + AF_NETLINK for HCI management.
    # Skip PrivateDevices (/dev/hci*), ProtectKernelModules (hci module loading).
    bluetooth = {
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
    user.services = {
      # Hyprland starts the Home Manager graphical session through this target
      # after exporting WAYLAND_DISPLAY/AQ_DRM_DEVICES into the user systemd
      # environment. Keep Sunshine on the same target so Wayland capture sees
      # the live session.
      sunshine = {
        after = lib.mkForce [ "nixos-fake-graphical-session.target" ];
        partOf = lib.mkForce [ "nixos-fake-graphical-session.target" ];
        wantedBy = lib.mkForce (
          lib.optionals config.services.sunshine.autoStart [ "nixos-fake-graphical-session.target" ]
        );
        wants = lib.mkForce [ "nixos-fake-graphical-session.target" ];
      };

      # The control center owns Bluetooth status/control now, so suppress the
      # redundant Blueman tray icon instead of autostarting blueman-applet.
      blueman-applet.enable = false;

      # The upstream dbus-broker unit is Type=notify-reload with no ExecReload,
      # so a reload sends SIGHUP and then blocks on the RELOADING=1/READY=1
      # sd_notify handshake. In user scope (dbus-broker-launch --scope user)
      # that handshake never arrives, so the reloadIfChanged path NixOS uses
      # for the session bus (see nixos/modules/services/system/dbus.nix) hangs
      # for the full timeout on every `nh os switch` and fails activation. Make
      # the reload a fire-and-forget SIGHUP instead: dbus-broker-launch
      # re-reads its service files on SIGHUP, and plain Type=notify returns as
      # soon as ExecReload exits rather than waiting on the reload-notification
      # protocol the user-scope launcher does not implement.
      dbus-broker.serviceConfig = {
        Type = lib.mkForce "notify";
        ExecReload = lib.mkForce "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
      };
    };

    services = {
      # This Intel CNVi adapter occasionally fails firmware download if btusb
      # probes as soon as udev sees the USB device:
      #
      #   Bluetooth: hci0: Failed to send firmware data (-38)
      #   usb 1-14: device descriptor read/64, error -71
      #
      # Keep btusb blacklisted above and load it here after early boot settles.
      bluetooth-load-btusb = {
        description = "Load Intel Bluetooth USB driver after early boot settles";
        requiredBy = [ "bluetooth.service" ];
        before = [ "bluetooth.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          sleep 5
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
  };

  # ── USB Device Control ─────────────────────────────────────────────────────
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

      # Allow Huawei EarPods (USB-C headphones) — audio interfaces only
      # ID: 12d1:3a06
      allow id 12d1:3a06 with-interface equals { 01:*:* }

      # Allow Intel CNVi Bluetooth (internal, Comet Lake AX201)
      # ID: 8087:0026
      allow id 8087:0026

      # Allow internal fingerprint reader (Synaptics; goodix-tod driver claims it)
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

  sops = {
    age.sshKeyPaths = [ "/persist/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile = ./secrets/secrets.yaml;
    secrets = {
      user_password.neededForUsers = true;
      observability_ingest_password = {
        group = "telemetry-ingest";
        mode = "0440";
      };
      restic_password = { };
      restic_repository = { };
      b2_credentials = { };
      initrd_ssh_host_ed25519_key = { };
    };
    templates."otel-env" = {
      content = "BASICAUTH_PASSWORD=${config.sops.placeholder.observability_ingest_password}";
      mode = "0400";
    };
  };

  users.groups.telemetry-ingest = { };

  users.users.user = {
    extraGroups = [
      "kvm"
      "libvirtd"
      "video"
    ];
    hashedPasswordFile = config.sops.secrets.user_password.path;
  };

}
