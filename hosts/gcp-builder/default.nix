{
  inputs,
  pkgs,
  ...
}:
let
  binaryCache = import ../../lib/binary-cache.nix;
in
{
  imports = [
    inputs.disko.nixosModules.disko
    ./hardware-configuration.nix
    ./disko.nix
    ../../modules/nixos/profiles/base.nix
    ../../modules/nixos/profiles/machine-common.nix
    ../../modules/nixos/profiles/security.nix
    ../../modules/nixos/profiles/sops-base.nix
    ../../modules/nixos/profiles/user.nix
  ];

  system = {
    stateVersion = "24.11";
  };

  # Broad passwordless sudo: deploy-rs needs it for activation. SSH/build access
  # to this target is therefore root-equivalent; keep SSH Tailscale-scoped and
  # key-only. This is a disposable, on-demand build box, not a service host.
  security.sudo.wheelNeedsPassword = false;

  networking = {
    hostName = "gcp-builder";
    firewall = {
      checkReversePath = "loose";
      interfaces.tailscale0.allowedTCPPorts = [ 22 ];
    };
  };

  boot = {
    # No ZFS here; pin the 26.11 default explicitly to avoid the eval warning.
    zfs.forceImportRoot = false;
    loader.timeout = 1;
    kernelParams = [
      "console=tty1"
      "console=ttyS0,115200n8"
      "systemd.journald.forward_to_console=1"
    ];
  };

  profiles = {
    # deploy-rs and `main`'s distributed builds connect as `user`; trust it so
    # the daemon accepts remote-build store operations and restricted settings.
    nix.extraTrustedUsers = [ "user" ];
  };

  nix = {
    settings = {
      trusted-public-keys = [
        binaryCache.cacheNixosOrgPublicKey
        binaryCache.mainLocalPublicKey
      ];
      # This box exists to build; let it use the whole VM.
      max-jobs = "auto";
      cores = 0;
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
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
  };

  environment.systemPackages = [
    # Keep common client terminal definitions available over SSH without pulling
    # every terminfo package into the server closure.
    pkgs.alacritty.terminfo
    pkgs.foot.terminfo
    pkgs.kitty.terminfo
    pkgs.wezterm.terminfo
  ];

  services = {
    openssh = {
      enable = true;
      openFirewall = false;
    };

    # Auto-join the tailnet on boot. SSH is tailnet-only, so the box MUST get
    # onto the tailnet without a login — otherwise it is unreachable after
    # install (you cannot `tailscale up` on a host you cannot log into, and it
    # has no console password). The auth key is placed at provisioning time via
    # `nixos-anywhere --extra-files` (see CLAUDE.md), not sops: a revocable,
    # tag-scoped auth key kept only on the builder's own disk. Mint it reusable,
    # NON-ephemeral (the box is usually powered off; an ephemeral node would be
    # deregistered while down and lose its stable name), pre-tagged tag:builder.
    # After first join the node identity persists on disk, so the key is used once.
    tailscale = {
      enable = true;
      openFirewall = true;
      authKeyFile = "/var/lib/tailscale-authkey";
      extraUpFlags = [ "--advertise-tags=tag:builder" ];
    };

    journald.extraConfig = ''
      ForwardToConsole=yes
      MaxLevelConsole=info
    '';
  };

  systemd = {
    services = {
      tailscale-authkey-cleanup =
        let
          authKeyPath = "/var/lib/tailscale-authkey";
          script = pkgs.writeShellScript "tailscale-authkey-cleanup" ''
            set -eu

            auth_key=${authKeyPath}

            for _ in $(${pkgs.coreutils}/bin/seq 1 60); do
              if ${pkgs.tailscale}/bin/tailscale status --json --peers=false 2>/dev/null \
                | ${pkgs.jq}/bin/jq -e '(.Self.ID? // "") != ""' >/dev/null; then
                ${pkgs.coreutils}/bin/shred --remove "$auth_key"
                exit 0
              fi

              ${pkgs.coreutils}/bin/sleep 1
            done

            echo "tailscale-authkey-cleanup: tailscale node identity was not established" >&2
            exit 1
          '';
        in
        {
          description = "Remove the gcp-builder Tailscale auth key after first join";
          wantedBy = [ "multi-user.target" ];
          wants = [ "tailscaled-autoconnect.service" ];
          after = [
            "tailscaled.service"
            "tailscaled-autoconnect.service"
          ];
          unitConfig.ConditionPathExists = authKeyPath;
          startLimitIntervalSec = 0;
          startLimitBurst = 1000000;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = script;
            Restart = "on-failure";
            RestartSec = "30s";
          };
        };

      # The builder is started on demand by `main` and powers itself off once it
      # has been idle (no established SSH/build connections) for idleSeconds. The
      # stamp lives in /run (tmpfs), so a fresh boot starts the idle clock from
      # now and gets a full grace window before the first shutdown check can fire.
      builder-idle-shutdown =
        let
          idleSeconds = 1200; # 20 minutes
          script = pkgs.writeShellScript "builder-idle-shutdown" ''
            set -eu
            stamp=/run/builder-last-active
            now=$(${pkgs.coreutils}/bin/date +%s)

            # Seed the stamp on the first run after boot so an unused boot still
            # gets a full idle window before shutting down.
            [ -f "$stamp" ] || ${pkgs.coreutils}/bin/printf '%s\n' "$now" > "$stamp"

            # Any established connection on port 22 means an interactive session
            # or an in-flight distributed build; treat the box as active.
            if ${pkgs.iproute2}/bin/ss -Htn state established '( sport = :22 )' \
                | ${pkgs.gnugrep}/bin/grep -q .; then
              ${pkgs.coreutils}/bin/printf '%s\n' "$now" > "$stamp"
              exit 0
            fi

            last=$(${pkgs.coreutils}/bin/cat "$stamp" 2>/dev/null || ${pkgs.coreutils}/bin/printf '%s' "$now")
            if [ "$(( now - last ))" -ge ${toString idleSeconds} ]; then
              ${pkgs.systemd}/bin/systemctl poweroff
            fi
          '';
        in
        {
          description = "Power off the build box after it has been idle";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = script;
          };
        };
    };

    timers.builder-idle-shutdown = {
      description = "Periodic idle check for the build box";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitActiveSec = "5min";
      };
    };
  };

  # Key-only login. No sops on this host, so no console/recovery password is
  # provisioned; recover a wedged builder by reprovisioning rather than console.
  # The build key authorizes root@main's nix-daemon to drive distributed builds
  # as this (trusted) user; it merges with the personal keys from sops-base.
  users.users.user = {
    home = "/home/user";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIESg3U6QT7ur+a/rRDksMKWOrOVS1uHr7u+LfhmgLl9U nix-remote-build-main-to-gcp-builder"
    ];
  };
}
