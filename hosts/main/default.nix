{
  config,
  inputs,
  pkgs,
  hostRegistry,
  self,
  lib,
  ...
}:
{
  imports = [
    ../../packages/network-doctor
    inputs.disko.nixosModules.disko
    inputs.lanzaboote.nixosModules.lanzaboote
    inputs.nix-index-database.nixosModules.default
    ./agent-maintenance.nix
    ./backups.nix
    ./bluetooth.nix
    ./boot.nix
    ./disko.nix
    ./gaming.nix
    ./impermanence.nix
    ./hardware-configuration.nix
    ./networking.nix
    ./nix-remote-build.nix
    ./power.nix
    ./services.nix
    ./usbguard.nix
    # Public modules by their exported names, so this host exercises the
    # same interface outside consumers import (flake/public-modules.nix).
    self.nixosModules.profiles-base
    self.nixosModules.profiles-desktop
    self.nixosModules.observability-client
    self.nixosModules.profiles-security
    ../../modules/nixos/profiles/sops-base.nix
    ../../modules/nixos/profiles/user.nix
    ../../modules/nixos/hardware/nvidia-prime.nix
    ../../modules/nixos/hardware/displaylink.nix
    ../../modules/nixos/hardware/synaptics-tudor.nix
    ../../modules/nixos/hardware/logitech-hidpp.nix
  ];

  networking.hostName = "main";

  hardware = {
    acpilight.enable = true;
    logitechHidpp.enable = true;
    synapticsTudor.enable = true;
    # The Turing GTX 1650 Ti stays awake with GSP enabled despite fine-grained
    # runtime PM. Use the proprietary driver's non-GSP path for idle power-off.
    # gsp.enable controls firmware inclusion; the module parameter selects the
    # driver mode. Both take effect after reboot, not a live system switch.
    nvidia = {
      gsp.enable = false;
      moduleParams.nvidia.NVreg_EnableGpuFirmware = 0;
    };
  };

  system.stateVersion = "24.11";

  profiles = {
    # Chosen from the shell's Spotlight when travelling; kept in /persist.
    runtimeTimezone = {
      enable = true;
      default = "Europe/London";
    };
    # deploy-rs passes store settings for remote builds; trust the local admin
    # user so the daemon accepts those restricted options without warning.
    nix.extraTrustedUsers = [ "user" ];

    observability-client = {
      enable = true;
      remoteEndpoint.host = hostRegistry.homeserver-gcp.tailnetFQDN;
      ingestAuth = {
        passwordFile = config.sops.secrets.observability_ingest_password.path;
      };
    };
    observability.collectors.metrics.scrapeInterval = "60s";
  };

  programs = {
    nix-index-database.comma.enable = true;
    virt-manager.enable = true;
    nix-ld.enable = true;
  };

  virtualisation.libvirtd = {
    enable = true;
    # Only x86_64 KVM guests (Whonix) run here; the default multi-target qemu
    # adds about 1 GiB of emulators for other architectures.
    qemu.package = pkgs.qemu_kvm;
  };

  # uv's standalone Python builds (and other non-Nix OpenSSL binaries) read the
  # OpenSSL default CA file /etc/ssl/cert.pem, which NixOS doesn't create, so TLS
  # verification failed in uv-run scripts. Point it at the system bundle.
  environment.etc."ssl/cert.pem".source =
    config.environment.etc."ssl/certs/ca-certificates.crt".source;

  environment.systemPackages = with pkgs; [
    spice-gtk
    swtpm
    virt-viewer
  ];

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
  systemd.user.services.dbus-broker.serviceConfig = {
    Type = lib.mkForce "notify";
    ExecReload = lib.mkForce "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
  };

  security.pam.services = lib.mkIf (!config.profiles.ci) {
    # hyprlock reads the fingerprint itself, so a password works at the same time.
    # Through PAM it would have to wait for the fingerprint attempt to end.
    hyprlock.fprintAuth = false;
    greetd.fprintAuth = true;
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
      initrd_ssh_host_ed25519_key = { };
      # The private ntfy topic that homeserver alerts and failures also use.
      failure_webhook_url = { };
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
