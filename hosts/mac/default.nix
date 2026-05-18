{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
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
in
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
    networkmanager.enable = true;
    firewall.interfaces.tailscale0.allowedTCPPorts = [ 22 ];
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
  };

  nixpkgs.config.permittedInsecurePackages = [
    "broadcom-sta-6.30.223.271-59-${config.boot.kernelPackages.kernel.version}"
  ];

  # Passwordless sudo: deploy-rs needs it for activation, access is SSH-key-only
  # over Tailscale, and the disk is LUKS-encrypted so console password loss does
  # not buy an attacker anything. Same posture as homeserver-gcp.
  security.sudo.wheelNeedsPassword = false;

  assertions = [
    {
      assertion = trustedUserViolations == [ ];
      message = "mac nix.settings.trusted-users must stay scoped to the local admin user: ${lib.concatStringsSep "; " trustedUserViolations}";
    }
  ];

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
    remoteEndpoint.host = "homeserver-gcp.tail90fc7a.ts.net";
  };

  # NetworkManager manages networking; avoid boot blocking on online targets.
  systemd.services = {
    "systemd-networkd-wait-online".enable = lib.mkForce false;
    "NetworkManager-wait-online".enable = lib.mkForce false;
  };

  environment.systemPackages = with pkgs; [
    efibootmgr
    nh
  ];

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
