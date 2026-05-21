{
  config,
  inputs,
  lib,
  pkgs,
  hostRegistry,
  ...
}:
let
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
  ];

  passwordlessAgentCommand = command: {
    inherit command;
    options = [ "NOPASSWD" ];
  };

  nixosSwitchMain = pkgs.writeShellScriptBin "nixos-switch-main" ''
    exec ${lib.getExe pkgs.nh} os switch --hostname main /home/user/nix
  '';

  nixGc14d = pkgs.writeShellScriptBin "nix-gc-14d" ''
    exec ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 14d
  '';

  expectedTrustedUsers = [
    "root"
    "user"
  ];
  actualTrustedUsers = config.nix.settings.trusted-users or [ ];
  missingTrustedUsers = lib.filter (
    user: !(builtins.elem user actualTrustedUsers)
  ) expectedTrustedUsers;
  unexpectedTrustedUsers = lib.filter (
    user: !(builtins.elem user expectedTrustedUsers)
  ) actualTrustedUsers;
  trustedUserViolations = lib.filter (msg: msg != "") [
    (lib.optionalString (
      missingTrustedUsers != [ ]
    ) "missing trusted users: ${lib.concatStringsSep ", " missingTrustedUsers}")
    (lib.optionalString (
      unexpectedTrustedUsers != [ ]
    ) "unexpected trusted users: ${lib.concatStringsSep ", " unexpectedTrustedUsers}")
  ];

  tailscaleBypassRules = pkgs.writeShellScript "tailscale-bypass-rules" ''
    set -eu

    ip_bin=${pkgs.iproute2}/bin/ip
    awk_bin=${pkgs.gawk}/bin/awk
    sleep_bin=${pkgs.coreutils}/bin/sleep

    tailscale_table=""
    for _attempt in 1 2 3 4 5; do
      tailscale_table=$(
        {
          "$ip_bin" rule show
          "$ip_bin" -6 rule show
          "$ip_bin" -o route show table all
          "$ip_bin" -o -6 route show table all
        } | "$awk_bin" '
          $0 ~ /^52[0-9][0-9]: from all lookup [0-9]+$/ { print $NF; exit }
          $1 ~ /^100\./ && $0 ~ /dev tailscale0/ && $0 ~ / table [0-9]+/ {
            for (i = 1; i <= NF; i++) if ($i == "table" && $(i + 1) ~ /^[0-9]+$/) { print $(i + 1); exit }
          }
          $1 ~ /^fd7a:115c:a1e0::/ && $0 ~ /dev tailscale0/ && $0 ~ / table [0-9]+/ {
            for (i = 1; i <= NF; i++) if ($i == "table" && $(i + 1) ~ /^[0-9]+$/) { print $(i + 1); exit }
          }
        '
      )

      if [ -n "$tailscale_table" ]; then
        break
      fi

      "$sleep_bin" 1
    done

    if [ -z "''${tailscale_table:-}" ]; then
      echo "tailscale-bypass-routing: could not discover tailscale routing table" >&2
      exit 0
    fi

    # Mullvad installs broad policy routing rules that can capture tailnet
    # traffic on this workstation. Reassert destination-specific rules with a
    # higher priority than Mullvad's catch-all policy rule so 100.x/ts.net
    # traffic always uses Tailscale's table.
    while "$ip_bin" rule del pref 120 to 100.64.0.0/10 2>/dev/null; do :; done
    while "$ip_bin" rule del pref 117 to 100.64.0.0/10 2>/dev/null; do :; done
    while "$ip_bin" rule del pref 114 to 100.64.0.0/10 2>/dev/null; do :; done
    "$ip_bin" rule add pref 114 to 100.64.0.0/10 lookup "$tailscale_table"

    while "$ip_bin" -6 rule del pref 120 to fd7a:115c:a1e0::/48 2>/dev/null; do :; done
    while "$ip_bin" -6 rule del pref 117 to fd7a:115c:a1e0::/48 2>/dev/null; do :; done
    while "$ip_bin" -6 rule del pref 114 to fd7a:115c:a1e0::/48 2>/dev/null; do :; done
    "$ip_bin" -6 rule add pref 114 to fd7a:115c:a1e0::/48 lookup "$tailscale_table"

    "$ip_bin" route flush cache 2>/dev/null || true
    "$ip_bin" -6 route flush cache 2>/dev/null || true
  '';
in
{
  imports = [
    inputs.disko.nixosModules.disko
    inputs.lanzaboote.nixosModules.lanzaboote
    inputs.nix-index-database.nixosModules.default
    ./dashboard.nix
    ./disko.nix
    ./impermanence.nix
    ./hardware-configuration.nix
    ../../modules/nixos/profiles/base.nix
    ../../modules/nixos/profiles/desktop.nix
    ../../modules/nixos/profiles/observability-client.nix
    ../../modules/nixos/profiles/security.nix
    ../../modules/nixos/profiles/sops-base.nix
    ../../modules/nixos/profiles/user.nix
    ../../modules/nixos/hardware/nvidia-prime.nix
  ];

  # ── Hardware ────────────────────────────────────────────────────────────────
  networking = {
    hostName = "main";
    networkmanager.enable = true;
    # Required because Mullvad + Tailscale create asymmetric VPN routing on this host.
    # Strict reverse-path filtering drops legitimate tunneled packets in that setup.
    # "loose" keeps a weaker source-reachability check, but relaxes anti-spoofing
    # protection compared with strict mode.
    firewall.checkReversePath = "loose";
    firewall.interfaces.tailscale0 = {
      allowedTCPPorts = [
        22
        24800
        47984
        47989
        48010
      ];
      allowedUDPPorts = [
        47998
        47999
        48000
        48002
        48010
      ];
    };
    # Point to systemd-resolved stub for split DNS (Tailscale tailnet hostnames)
    nameservers = [ "127.0.0.53" ];
  };

  hardware = {
    bluetooth = {
      enable = true;
      powerOnBoot = true;
    };
    acpilight.enable = true;
  };

  system.stateVersion = "24.11";

  time.timeZone = "Europe/London";

  # deploy-rs passes store settings for remote builds; trust the local admin
  # user so the daemon accepts those restricted options without warning.
  profiles.nix.extraTrustedUsers = [ "user" ];

  nix.settings = {
    extra-substituters = [ "https://pub-706604c9179043ac98604d6de4c65c2c.r2.dev" ];
    extra-trusted-public-keys = [
      # Keep this in sync with the CI signing key used for the R2 binary cache.
      "nix-cache-1:eEcFiWPHQpJmlcnNeGoPg6xxOp3itNZiWwFaE+NebIk="
    ];
  };

  programs.nix-index-database.comma.enable = true;

  # Hidden maintenance mount for the filesystem top-level. btrbk snapshots
  # subvolumes by their real top-level names (`@home`, `@persist`) rather than
  # via nested mount paths.
  fileSystems."/.btrfs-root" = {
    device = "/dev/disk/by-label/main-root";
    fsType = "btrfs";
    options = [
      "subvol=/"
      "noatime"
      "discard=async"
    ];
  };

  environment.systemPackages = with pkgs; [
    efibootmgr
    nh
    nixGc14d
    nixosSwitchMain
    sbctl
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

  assertions = [
    {
      assertion = trustedUserViolations == [ ];
      message = "main nix.settings.trusted-users must stay scoped to the local admin user: ${lib.concatStringsSep "; " trustedUserViolations}";
    }
  ];

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
    resolved = {
      enable = true;
      settings.Resolve.DNSSEC = "false"; # Tailscale manages its own trust chain
    };

    sunshine = {
      enable = true;
      autoStart = true;
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
    btrbk.instances.local = {
      onCalendar = "daily";
      snapshotOnly = true;
      settings = {
        snapshot_preserve_min = "2d";
        snapshot_preserve = "14d";
        volume."/.btrfs-root" = {
          snapshot_dir = ".snapshots";
          subvolume = {
            "@home" = { };
            "@persist" = { };
          };
        };
      };
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

    tailscale = {
      enable = true;
      openFirewall = true;
    };

    mullvad-vpn.enable = true;

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

    # ── Backups ────────────────────────────────────────────────────────────────
    restic.backups.local = {
      paths = [
        "/home/user/.ssh"
        "/home/user/.gnupg"
        "/home/user/nix"
        "/home/user/.mozilla/firefox"
        "/home/user/.config/mozilla/firefox"
        "/home/user/.config/spotify"
        "/home/user/.config/discord"
        "/home/user/.config/gh"
        "/home/user/.config/gcloud"
        "/home/user/.local/share/Anki2"
        "/home/user/.config/chromium"
        "/home/user/.local/share/kwalletd"
        "/home/user/.codex"
        "/home/user/.claude"
        "/home/user/.claude.json"
        "/home/user/.config/sops"
        "/etc/machine-id"
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
        "/etc/NetworkManager/system-connections"
        "/etc/mullvad-vpn"
        "/var/lib/tailscale"
        "/var/lib/bluetooth"
        "/var/lib/fprint"
        "/var/lib/sbctl"
        "/var/lib/usbguard"
      ];
      exclude = [
        # Token/credential caches — not durable; regenerated on next gcloud auth
        "/home/user/.config/gcloud/access_tokens.db"
        "/home/user/.config/gcloud/credentials.db"
        "/home/user/.config/gcloud/logs"
        "/home/user/.config/gcloud/legacy_credentials"
      ];
      repositoryFile = config.sops.secrets.restic_repository.path;
      passwordFile = config.sops.secrets.restic_password.path;
      environmentFile = config.sops.secrets.b2_credentials.path;
    };
  };

  profiles.observability-client = {
    enable = true;
    remoteEndpoint.host = hostRegistry.homeserver-gcp.tailnetFQDN;
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
      ];
      extraConfig = {
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
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

  # NetworkManager manages networking; avoid boot blocking on online targets.
  systemd = {
    # Hyprland starts the Home Manager graphical session through this target
    # after exporting WAYLAND_DISPLAY/AQ_DRM_DEVICES into the user systemd
    # environment. Keep Sunshine on the same target so Wayland capture sees the
    # live session.
    user.services.sunshine = {
      after = lib.mkForce [ "nixos-fake-graphical-session.target" ];
      partOf = lib.mkForce [ "nixos-fake-graphical-session.target" ];
      wantedBy = lib.mkForce [ "nixos-fake-graphical-session.target" ];
      wants = lib.mkForce [ "nixos-fake-graphical-session.target" ];
    };

    # The control center owns Bluetooth status/control now, so suppress the
    # redundant Blueman tray icon instead of autostarting blueman-applet.
    user.services.blueman-applet.enable = false;

    services = {
      # Policy.AutoEnable races the Intel CNVi adapter's MGMT init on this
      # machine (bluetoothd logs "Failed to set default system config for hci0"
      # at boot and leaves hci0 powered off). Force it on via D-Bus once the
      # /org/bluez/hci0 object is exposed. bluetoothctl is unusable here: in
      # non-interactive mode it silently no-ops and exits 0 regardless of state.
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

      "systemd-networkd-wait-online".enable = lib.mkForce false;
      "NetworkManager-wait-online".enable = lib.mkForce false;

      restic-backups-local.serviceConfig.ExecStartPost = pkgs.writeShellScript "restic-backup-metrics" ''
        tmp=/var/lib/node-exporter-textfiles/restic_backup.prom.tmp
        {
          echo "# HELP restic_last_backup_timestamp_seconds Unix timestamp of last successful restic backup"
          echo "# TYPE restic_last_backup_timestamp_seconds gauge"
          echo "restic_last_backup_timestamp_seconds $(date +%s)"
        } > "$tmp"
        mv "$tmp" /var/lib/node-exporter-textfiles/restic_backup.prom
      '';

      restic-check-local = {
        description = "Restic workstation repository integrity check";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        environment.RESTIC_PASSWORD_FILE = config.sops.secrets.restic_password.path;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.restic}/bin/restic check --repository-file=${config.sops.secrets.restic_repository.path} --read-data-subset=1G";
          ExecStartPost = pkgs.writeShellScript "restic-check-metrics" ''
            tmp=/var/lib/node-exporter-textfiles/restic_check.prom.tmp
            {
              echo "# HELP restic_last_check_timestamp_seconds Unix timestamp of last successful restic integrity check"
              echo "# TYPE restic_last_check_timestamp_seconds gauge"
              echo "restic_last_check_timestamp_seconds $(date +%s)"
            } > "$tmp"
            mv "$tmp" /var/lib/node-exporter-textfiles/restic_check.prom
          '';
          EnvironmentFile = config.sops.secrets.b2_credentials.path;
        };
      };

      tailscale-bypass-routing = {
        description = "Keep tailnet traffic off the Mullvad tunnel";
        after = [
          "tailscaled.service"
          "mullvad-daemon.service"
        ];
        wants = [
          "tailscaled.service"
          "mullvad-daemon.service"
        ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = tailscaleBypassRules;
        };
      };

      tailscaled.postStart = lib.mkAfter "${tailscaleBypassRules}";
      mullvad-daemon.postStart = lib.mkAfter "${tailscaleBypassRules}";

      # Mullvad's lockdown mode installs an nftables killswitch (policy drop +
      # `reject with tcp reset` on every output chain) that kills tailscale0
      # traffic the same way it kills clearnet traffic — every TCP connection
      # to a 100.64/10 peer gets an immediate RST.
      #
      # The bypass routing script above only fixes *routing*, not filtering, so
      # it cannot rescue Tailscale on its own. Disable lockdown so that when
      # Mullvad is disconnected (the default state) no killswitch firewall is
      # active and Tailscale can use the normal NixOS firewall.
      #
      # Trade-off: while Mullvad is *actively connected* its in-tunnel firewall
      # still blocks tailscale0. Use one VPN at a time — `mullvad disconnect`
      # before relying on the tailnet.
      mullvad-tailscale-coexist = {
        description = "Disable Mullvad lockdown so Tailscale can coexist";
        after = [ "mullvad-daemon.service" ];
        bindsTo = [ "mullvad-daemon.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
            ${pkgs.mullvad-vpn}/bin/mullvad status >/dev/null 2>&1 && break
            ${pkgs.coreutils}/bin/sleep 1
          done
          ${pkgs.mullvad-vpn}/bin/mullvad lockdown-mode set off
          ${pkgs.mullvad-vpn}/bin/mullvad auto-connect set off
        '';
      };
    };

    timers.restic-check-local = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        RandomizedDelaySec = "2h";
        Persistent = true;
      };
    };
  };

  # ── USB Device Control ─────────────────────────────────────────────────────
  services.usbguard = {
    enable = true;
    rules = ''
      # Default policy: block all USB devices
      # Devices must be explicitly whitelisted below

      # Allow Logitech USB Receiver (mouse)
      # ID: 046d:c54d
      allow id 046d:c54d

      # Allow Huawei EarPods (USB-C headphones)
      # ID: 12d1:3a06
      allow id 12d1:3a06

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
  };

  users.groups.telemetry-ingest = { };

  users.users.user = {
    extraGroups = [ "video" ];
    hashedPasswordFile = config.sops.secrets.user_password.path;
  };

}
