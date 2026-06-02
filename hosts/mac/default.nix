{
  config,
  inputs,
  lib,
  pkgs,
  hostRegistry,
  ...
}:
{
  imports = [
    inputs.disko.nixosModules.disko
    inputs.nix-index-database.nixosModules.default
    ./disko.nix
    ./hardware-configuration.nix
    ./impermanence.nix
    ../../modules/nixos/profiles/base.nix
    ../../modules/nixos/profiles/desktop.nix
    ../../modules/nixos/profiles/machine-common.nix
    ../../modules/nixos/profiles/observability-client.nix
    ../../modules/nixos/profiles/security.nix
    ../../modules/nixos/profiles/sops-base.nix
    ../../modules/nixos/profiles/user.nix
  ];

  system.stateVersion = "24.11";

  time.timeZone = "Europe/London";

  networking = {
    hostName = "mac";
    networkmanager = {
      enable = true;
      # NetworkManager owns wired/tether; wlp3s0 is driven by a dedicated
      # wpa_supplicant unit below because NM defaults to the nl80211 driver,
      # which the proprietary Broadcom `wl` module rejects with "Association
      # request to the driver failed" on the campus WPA-EAP APs (FT handshake).
      unmanaged = [ "interface-name:wlp3s0" ];
      settings = {
        connection."wifi.cloned-mac-address" = "permanent";
        device."wifi.scan-rand-mac-address" = "no";
      };
    };
    firewall.interfaces.tailscale0 = {
      allowedTCPPorts = [
        22
        22000
      ];
      allowedUDPPorts = [
        22000
        21027
      ];
    };
    # Loose reverse-path filtering: this host commonly has two live default
    # routes (Wi-Fi + USB-Ethernet/iPhone tether). Strict rpfilter drops the
    # WiFi return traffic because the FIB best-route lookup picks the lower-
    # metric tether, even though the packet legitimately arrived on wlp3s0.
    firewall.checkReversePath = "loose";

    # Dedicated dhcpcd for wlp3s0 (NM disables dhcpcd globally and runs its
    # own DHCP for managed interfaces). useDHCP on the iface flips the gate
    # that actually generates the systemd unit.
    dhcpcd.enable = true;
    interfaces.wlp3s0.useDHCP = true;
  };

  # ── Hardware ────────────────────────────────────────────────────────────────
  # 2017 MacBook Air (A1466). No T2 → no Secure Boot enrollment lockout, no TPM.
  # The BCM4360 Wi-Fi chipset needs the proprietary broadcom_sta module; the
  # in-kernel open-source drivers do not handle it. broadcom-sta is unmaintained
  # and CVE-flagged (CVE-2019-9501/9502); we accept the risk on this companion
  # host because the alternative is no Wi-Fi at all on this hardware. Wired
  # USB-Ethernet bypasses the driver entirely. enableRedistributableFirmware
  # covers the rest of the Apple firmware blobs.
  hardware.enableRedistributableFirmware = true;

  boot = {
    kernelModules = [ "wl" ];
    extraModulePackages = [ config.boot.kernelPackages.broadcom_sta ];
    loader = {
      systemd-boot = {
        enable = true;
        configurationLimit = 5;
      };
      efi.canTouchEfiVariables = false;
      timeout = 3;
    };
    kernelParams = [
      "intel_iommu=on"
      "mem_sleep_default=deep"
    ];

    # LUKS auto-unlock via a keyfile baked into the initrd. This pre-2018
    # MacBook Air has no TPM/T2 and no FIDO2 token yet, and the laptop stays
    # at home, so we trade at-rest protection for boot convenience. The
    # initrd lives on the unencrypted ESP, so anyone with the powered laptop
    # is in — the disk is only protected if pulled from the machine. Revert
    # this block (and remove the LUKS key slot with `cryptsetup luksRemoveKey`)
    # before the host travels.
    initrd = {
      # systemd stage 1 always falls back to interactive passphrase prompts
      # when the keyfile is missing/wrong — no `fallbackToPassword` needed.
      luks.devices.cryptroot.keyFile = "/luks.key";
      secrets = {
        "/luks.key" = config.sops.secrets.luks_keyfile.path;
      };
    };
  };

  nixpkgs.config.permittedInsecurePackages = [
    "broadcom-sta-6.30.223.271-59-${config.boot.kernelPackages.kernel.version}"
  ];

  # Broad passwordless sudo: deploy-rs needs it for activation. SSH access to
  # this target is therefore root-equivalent; keep SSH Tailscale-scoped and
  # key-only. Same posture as homeserver-gcp.
  security.sudo.wheelNeedsPassword = false;

  # deploy-rs passes store settings for remote builds; trust the local admin
  # user so the daemon accepts those restricted options without warning.
  profiles.nix.extraTrustedUsers = [ "user" ];

  nix = {
    settings = {
      extra-substituters = [ "https://pub-706604c9179043ac98604d6de4c65c2c.r2.dev" ];
      extra-trusted-public-keys = [
        "nix-cache-1:eEcFiWPHQpJmlcnNeGoPg6xxOp3itNZiWwFaE+NebIk="
      ];
    };

    # 128 GB SSD fills quickly with generations and closure churn. Override the
    # fleet default (`base.nix`: --delete-older-than 7d) with a tighter window.
    gc.options = lib.mkForce "--delete-older-than 7d";
  };

  programs.nix-index-database.comma.enable = true;

  # ── Services ────────────────────────────────────────────────────────────
  services = {
    resolved = {
      enable = true;
      settings.Resolve.DNSSEC = "false";
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
      openFirewall = false; # Accessible via Tailscale only.
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

    # Stay awake on AC (companion usage: Syncthing reachable, tmux available);
    # suspend when running on battery to preserve the small 8 GB LPDDR3 host.
    logind.settings.Login = {
      HandleLidSwitch = "suspend";
      HandleLidSwitchExternalPower = "ignore";
      IdleAction = "suspend";
      IdleActionSec = "15min";
    };

    systemd-failure-notify = {
      enable = true;
      services = [
        "thermald"
        "power-profiles-daemon"
      ];
    };
  };

  profiles.observability-client = {
    enable = true;
    remoteEndpoint.host = hostRegistry.homeserver-gcp.tailnetFQDN;
    ingestAuth = {
      passwordFile = config.sops.secrets.observability_ingest_password.path;
      serviceEnvironmentFile = config.sops.templates."otel-env".path;
    };
  };

  # NetworkManager manages networking; avoid boot blocking on online targets.
  systemd.services = {
    "systemd-networkd-wait-online".enable = lib.mkForce false;
    "NetworkManager-wait-online".enable = lib.mkForce false;

    # Remote deploys arrive over Tailscale, usually through the Broadcom Wi-Fi
    # path below. Stopping any of these during switch cuts the SSH session
    # before deploy-rs can confirm activation, causing magic rollback and a
    # console-looking failure on the Mac.
    NetworkManager = {
      restartIfChanged = false;
      stopIfChanged = false;
    };
    dhcpcd = {
      restartIfChanged = false;
      stopIfChanged = false;
    };
    systemd-resolved = {
      restartIfChanged = false;
      stopIfChanged = false;
    };
    tailscaled = {
      restartIfChanged = false;
      stopIfChanged = false;
    };
    sshd = {
      restartIfChanged = false;
      stopIfChanged = false;
    };
    wpa_supplicant = {
      restartIfChanged = false;
      stopIfChanged = false;
    };
  };

  environment.systemPackages = with pkgs; [
    efibootmgr
    nh
  ];

  # ── Wi-Fi (campus WPA-EAP, wext driver) ─────────────────────────────────────
  # NetworkManager + nl80211 cannot drive the BCM4360 against the campus
  # WPA-EAP APs (driver rejects FT-aware association). This unit runs a
  # per-interface wpa_supplicant in wext mode against a wpa_supplicant.conf
  # delivered as a single sops secret (SSIDs, identities, password, and
  # certificate pin live together in the encrypted blob). dhcpcd (above)
  # handles DHCP once associated.
  systemd.services.wpa-supplicant-wlp3s0 = {
    description = "WPA Supplicant for wlp3s0 (wext driver, campus WPA-EAP)";
    wantedBy = [ "multi-user.target" ];
    restartIfChanged = false;
    stopIfChanged = false;
    after = [
      "network-pre.target"
      "sops-install-secrets.service"
    ];
    wants = [ "sops-install-secrets.service" ];
    before = [ "network.target" ];

    path = with pkgs; [
      wpa_supplicant
      iproute2
    ];

    preStart = ''
      install -d -m 700 /run/wpa_supplicant
      ip link set wlp3s0 up || true
    '';

    script = ''
      exec wpa_supplicant -i wlp3s0 -D wext -c ${config.sops.secrets.wpa_supplicant_wlp3s0_conf.path}
    '';

    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "5s";
    };
  };

  # ── Secrets ─────────────────────────────────────────────────────────────────
  # SSH host key bind-mounted from /persist by impermanence-base.nix. The key
  # is pre-generated and committed encrypted to hosts/mac/secrets/; it is
  # injected into /persist/etc/ssh/ via `nixos-anywhere --extra-files` during
  # the initial install, so sops can decrypt on first boot.
  sops = {
    age.sshKeyPaths = [ "/persist/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile = ./secrets/secrets.yaml;
    secrets = {
      user_password.neededForUsers = true;
      root_password.neededForUsers = true;
      wpa_supplicant_wlp3s0_conf = {
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ ];
      };
      luks_keyfile = {
        format = "binary";
        sopsFile = ./secrets/luks-keyfile.enc;
        mode = "0400";
      };
      observability_ingest_password = {
        group = "telemetry-ingest";
        mode = "0440";
      };
    };
    templates."otel-env" = {
      content = "BASICAUTH_PASSWORD=${config.sops.placeholder.observability_ingest_password}";
      mode = "0400";
    };
  };

  users.users.user = {
    extraGroups = [ "video" ];
    hashedPasswordFile = config.sops.secrets.user_password.path;
  };

  # Root password is set so console su works if the desktop session breaks.
  # SSH root login is disabled by profiles/security.nix (PermitRootLogin = no),
  # and SSH password auth is off, so this password is console-only.
  users.users.root.hashedPasswordFile = config.sops.secrets.root_password.path;
}
