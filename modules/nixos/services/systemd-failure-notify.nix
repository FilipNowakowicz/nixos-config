{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.systemd-failure-notify;
  webhookEnabled = cfg.webhookUrlFile != null;

  # The failed unit name is passed as $1 from the template unit's ExecStart
  # (the %i instance specifier). systemd does not export $SYSTEMD_UNIT to
  # ExecStart, so the instance must be passed explicitly.
  notifyScript = pkgs.writeShellScript "systemd-failure-notify" ''
    set -euo pipefail
    SERVICE_NAME="''${1%.*}"
    TIMESTAMP=$(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S')
    HOSTNAME="${config.networking.hostName}"
    MESSAGE="[$TIMESTAMP] Service $SERVICE_NAME failed unexpectedly on $HOSTNAME"

    # Log to journal
    echo "$MESSAGE" | ${pkgs.systemd}/bin/systemd-cat -t systemd-failure-notify -p warning

    # Post to an off-host webhook when configured. The URL is supplied through
    # systemd credentials so secrets stay out of the Nix store and process args.
    WEBHOOK_URL_FILE="''${CREDENTIALS_DIRECTORY:-}/webhook_url"
    if [[ -r "$WEBHOOK_URL_FILE" ]]; then
      WEBHOOK_URL="$(<"$WEBHOOK_URL_FILE")"
      if [[ -n "$WEBHOOK_URL" ]]; then
        if ! ${pkgs.curl}/bin/curl \
          --fail \
          --silent \
          --show-error \
          --max-time 10 \
          --retry 2 \
          --retry-delay 2 \
          --data-binary "$MESSAGE" \
          "$WEBHOOK_URL" >/dev/null; then
          echo "[$TIMESTAMP] Failed to post failure notification for $SERVICE_NAME to webhook" \
            | ${pkgs.systemd}/bin/systemd-cat -t systemd-failure-notify -p warning
        fi
      fi
    fi

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

    webhookUrlFile = lib.mkOption {
      type = with lib.types; nullOr path;
      default = null;
      description = ''
        Optional runtime file containing an off-host webhook URL. When set, the
        failure template posts a compact text notification to this URL using a
        systemd credential, so the URL is not rendered into the Nix store or
        process arguments.
      '';
      example = lib.literalExpression "config.sops.secrets.alertmanager_webhook_url.path";
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
        ${lib.optionalString webhookEnabled "LoadCredential=webhook_url:${toString cfg.webhookUrlFile}"}
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
