# What the on-demand GCE hosts (gcp-builder, gcp-worker) share on top of
# gce-server.nix: they join the tailnet on first boot with an auth key placed at
# provisioning time, and power themselves off once nothing has used them for a
# while. `main` starts them with gcloud when it needs them.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.profiles.gceOnDemand;
  authKeyPath = "/var/lib/tailscale-authkey";
  idleUnit = "${cfg.name}-idle-shutdown";
in
{
  options.profiles.gceOnDemand = {
    enable = lib.mkEnableOption "an on-demand GCE host that joins the tailnet by auth key and powers off when idle";

    name = lib.mkOption {
      type = lib.types.str;
      description = "Prefix for the idle-shutdown units and stamp, e.g. `builder`.";
    };

    tag = lib.mkOption {
      type = lib.types.str;
      description = "Tailscale tag the host advertises, without `tag:`.";
    };

    idleSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1200;
      description = "Power off after this long with no SSH connection and no busy work.";
    };

    busyCheck = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Shell run by the idle check. Exit 0 from it (via `exit 0` after
        `mark_active`) to keep the host up; the snippet runs before the SSH
        check, with `mark_active` defined to refresh the idle stamp.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # SSH is tailnet-only, so the box MUST get onto the tailnet without a login:
    # you cannot `tailscale up` on a host you cannot log into, and it has no
    # console password. The auth key is placed at provisioning time via
    # `nixos-anywhere --extra-files` (see the host's CLAUDE.md), not sops: a
    # revocable, tag-scoped key kept only on the host's own disk. Mint it
    # reusable and NON-ephemeral (the box is usually off; an ephemeral node would
    # be deregistered while down and lose its stable name), pre-tagged. After the
    # first join the node identity persists on disk, so the key is used once.
    services.tailscale = {
      authKeyFile = authKeyPath;
      # gce-server.nix adds --reset, so the tag must be mentioned here to survive.
      extraUpFlags = lib.mkBefore [ "--advertise-tags=tag:${cfg.tag}" ];
    };

    systemd = {
      services = {
        tailscale-authkey-cleanup =
          let
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
            description = "Remove the ${config.networking.hostName} Tailscale auth key after first join";
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

        # The stamp lives in /run (tmpfs), so a fresh boot starts the idle clock
        # from now and gets a full grace window before the first shutdown check.
        ${idleUnit} =
          let
            script = pkgs.writeShellScript idleUnit ''
              set -eu
              stamp=/run/${cfg.name}-last-active
              now=$(${pkgs.coreutils}/bin/date +%s)

              mark_active() {
                ${pkgs.coreutils}/bin/printf '%s\n' "$now" > "$stamp"
              }

              # Seed the stamp on the first run after boot so an unused boot still
              # gets a full idle window before shutting down.
              [ -f "$stamp" ] || mark_active

              ${cfg.busyCheck}

              # Any established connection on port 22 means an interactive session
              # or an in-flight distributed build; treat the box as active.
              if ${pkgs.iproute2}/bin/ss -Htn state established '( sport = :22 )' \
                  | ${pkgs.gnugrep}/bin/grep -q .; then
                mark_active
                exit 0
              fi

              last=$(${pkgs.coreutils}/bin/cat "$stamp" 2>/dev/null || ${pkgs.coreutils}/bin/printf '%s' "$now")
              if [ "$(( now - last ))" -ge ${toString cfg.idleSeconds} ]; then
                ${pkgs.systemd}/bin/systemctl poweroff
              fi
            '';
          in
          {
            description = "Power off ${config.networking.hostName} after it has been idle";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = script;
            };
          };
      };

      timers.${idleUnit} = {
        description = "Periodic idle check for ${config.networking.hostName}";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "10min";
          OnUnitActiveSec = "5min";
        };
      };
    };
  };
}
