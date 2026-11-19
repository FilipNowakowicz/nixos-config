{
  inputs,
  pkgs,
  ...
}:
{
  imports = [
    inputs.disko.nixosModules.disko
    ./prebuilt.nix
    ./disko.nix
    ../../modules/nixos/profiles/gce-server.nix
    ../../modules/nixos/profiles/gce-on-demand.nix
  ];

  system = {
    stateVersion = "24.11";
  };

  # gce-server.nix grants broad passwordless sudo and trusts `user` for remote
  # builds, so SSH/build access here is root-equivalent. This is a disposable,
  # on-demand build box, not a service host.

  networking = {
    hostName = "gcp-builder";
    firewall.interfaces.tailscale0.allowedTCPPorts = [ 22 ];
  };

  nix = {
    settings = {
      # This box exists to build; let it use the whole VM.
      max-jobs = "auto";
      cores = 0;
      # The VM is off most of the time, so a GC timer would rarely fire. Free
      # space during builds instead (10 and 30 GiB).
      min-free = 10737418240;
      max-free = 32212254720;
      # Advertise build capabilities so `main` can offload the KVM-backed nixos
      # test suite here. KVM requires the GCE instance to have nested
      # virtualization enabled (see infra/builder.tf — n2 family).
      system-features = [
        "nixos-test"
        "benchmark"
        "big-parallel"
        "kvm"
      ];
    };
  };

  profiles.gceOnDemand = {
    enable = true;
    name = "builder";
    tag = "builder";
    # A boot prebuild has no SSH connection. Its systemd start timeout bounds
    # this inhibition to three hours (plus termination grace).
    busyCheck = ''
      case "$(${pkgs.systemd}/bin/systemctl show builder-prebuild.service --property=ActiveState --value)" in
        activating|active|deactivating)
          mark_active
          exit 0
          ;;
      esac
    '';
  };

  # Key-only login. No sops on this host, so no console/recovery password is
  # provisioned; recover a wedged builder by reprovisioning rather than console.
  # The main build key authorizes root@main's nix-daemon to drive distributed
  # builds as this (trusted) user; these merge with the personal keys from
  # sops-base.
  users.users.user = {
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC+J1RPvpFJ6zpeeio5N6xWIcSIdBfgmjOexo27FGLLw github-ci-gcp-builder"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIESg3U6QT7ur+a/rRDksMKWOrOVS1uHr7u+LfhmgLl9U nix-remote-build-main-to-gcp-builder"
    ];
  };
}
