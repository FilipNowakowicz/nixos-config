{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.systemd-failure-notify;

  # The failed unit name is passed as $1 from the template unit's ExecStart
  # (the %i instance specifier). systemd does not export $SYSTEMD_UNIT to
  # ExecStart, so the instance must be passed explicitly.
  notifyScript = pkgs.writeShellScript "systemd-failure-notify" ''
    set -euo pipefail
    SERVICE_NAME="''${1%.*}"
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Log to journal
    echo "[$TIMESTAMP] Service $SERVICE_NAME failed unexpectedly" | systemd-cat -t systemd-failure-notify -p warning

    # Try to send desktop notification if display is available
    if [[ -n "''${DISPLAY:-}" || -n "''${WAYLAND_DISPLAY:-}" ]]; then
      export PATH="${pkgs.libnotify}/bin:$PATH"
      notify-send -a "systemd" -u critical "Service Failed" "$SERVICE_NAME failed at $TIMESTAMP" 2>/dev/null || true
    fi
  '';
in
{
  options.services.systemd-failure-notify = {
    enable = lib.mkEnableOption "desktop notifications for systemd service failures";

    services = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "List of service names to attach failure notifications to (e.g. ['nginx' 'redis-server'])";
      example = [
        "nginx"
        "postgresql"
      ];
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ libnotify ];

    # Template unit for failure notifications
    systemd.units."notify-failure@.service" = {
      text = ''
        [Unit]
        Description=Notify on %i failure
        After=syslog.target network-online.target remote-fs.target nss-lookup.target

        [Service]
        Type=oneshot
        ExecStart=${notifyScript} %i
        StandardOutput=journal
        StandardError=journal
      '';
    };

    # Attach OnFailure to specified services
    systemd.services = lib.mkMerge (
      map (serviceName: {
        "${serviceName}" = {
          onFailure = [ "notify-failure@${serviceName}.service" ];
        };
      }) cfg.services
    );
  };
}
