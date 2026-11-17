{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    inputs.disko.nixosModules.disko
    ./prebuilt.nix
    ./disko.nix
    ../../modules/nixos/profiles/gce-server.nix
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

  services = {
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
      authKeyFile = "/var/lib/tailscale-authkey";
      # gce-server.nix adds --reset, so the tag must be mentioned here to survive.
      extraUpFlags = lib.mkBefore [ "--advertise-tags=tag:builder" ];
    };
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

            # A boot prebuild has no SSH connection. Its systemd start timeout
            # bounds this inhibition to three hours (plus termination grace).
            case "$(${pkgs.systemd}/bin/systemctl show builder-prebuild.service --property=ActiveState --value)" in
              activating|active|deactivating)
                ${pkgs.coreutils}/bin/printf '%s\n' "$now" > "$stamp"
                exit 0
                ;;
            esac

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
