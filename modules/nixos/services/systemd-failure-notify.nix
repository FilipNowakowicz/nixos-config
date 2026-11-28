{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.systemd-failure-notify;
  ntfyEnabled = cfg.ntfy.url != null;
  webhookEnabled = cfg.webhookUrlFile != null;

  ntfyLib = import ../../../lib/ntfy.nix { };

  # The failed unit name is passed from the template unit's ExecStart (the %i
  # instance specifier). systemd does not export $SYSTEMD_UNIT to ExecStart, so
  # the instance must be passed explicitly. A first `--fallback` argument skips
  # the ntfy server and posts straight to the fallback webhook.
  #
  # systemd-cat is given the command to run. Without one it execs `cat` from
  # $PATH, and this raw template unit inherits only the service manager's
  # PATH, which has no coreutils. That made the first log line fail and
  # `set -e` exit before the webhook on every host. Journal logging is also
  # best-effort so it can never block the off-host notification.
  #
  # Both destinations are ntfy topics, so both get the same title, priority
  # and source tags. Secrets come in as systemd credentials, so neither the
  # token nor the webhook URL reaches the Nix store or process arguments (the
  # token goes to curl through a --config pipe, not its command line).
  notifyScript = pkgs.writeShellScript "systemd-failure-notify" ''
    set -euo pipefail
    log() {
      ${pkgs.systemd}/bin/systemd-cat -t systemd-failure-notify -p warning \
        ${pkgs.coreutils}/bin/printf '%s\n' "$1" || printf '%s\n' "$1" >&2
    }
    direct=false
    if [[ $1 == --fallback ]]; then
      direct=true
      shift
    fi
    UNIT="$1"
    SERVICE_NAME="''${UNIT%.*}"
    TIMESTAMP=$(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S')
    HOSTNAME="${config.networking.hostName}"
    MESSAGE="[$TIMESTAMP] Service $SERVICE_NAME failed unexpectedly on $HOSTNAME. Check: journalctl -u $SERVICE_NAME"
    case "$SERVICE_NAME" in
      ${lib.concatStrings (
        lib.mapAttrsToList (unit: source: ''
          ${lib.escapeShellArg unit}) TAGS=${lib.escapeShellArg (ntfyLib.tags source)} ;;
        '') cfg.unitSources
      )}
      *) TAGS=${lib.escapeShellArg (ntfyLib.tags cfg.source)} ;;
    esac

    log "$MESSAGE"

    post() {
      ${pkgs.curl}/bin/curl \
        --fail \
        --silent \
        --show-error \
        --max-time 10 \
        --retry 2 \
        --retry-delay 2 \
        -H "Title: $SERVICE_NAME failed on $HOSTNAME" \
        -H "Priority: high" \
        -H "Tags: $TAGS" \
        --data-binary "$MESSAGE" \
        "$@" >/dev/null
    }

    credential() {
      local file="''${CREDENTIALS_DIRECTORY:-}/$1"
      [[ -r $file ]] && printf '%s' "$(<"$file")"
    }

    sent=false
    if ! $direct && token=$(credential ntfy_token) && [[ -n $token ]]; then
      if post --config <(printf 'header = "Authorization: Bearer %s"\n' "$token") ${lib.escapeShellArg (toString cfg.ntfy.url)}; then
        sent=true
      else
        log "[$TIMESTAMP] Failed to post failure notification for $SERVICE_NAME to ntfy"
      fi
    fi
    # The fallback webhook takes the units that skip ntfy, and any message
    # ntfy could not take.
    if ! $sent && url=$(credential webhook_url) && [[ -n $url ]]; then
      post "$url" ||
        log "[$TIMESTAMP] Failed to post failure notification for $SERVICE_NAME to webhook"
    fi

    # Try to send desktop notification if display is available
    if [[ -n "''${DISPLAY:-}" || -n "''${WAYLAND_DISPLAY:-}" ]]; then
      export PATH="${pkgs.libnotify}/bin:$PATH"
      notify-send -a "systemd" -u critical "Service Failed" "$SERVICE_NAME failed at $TIMESTAMP" 2>/dev/null || true
    fi
  '';

  template =
    { fallback }:
    ''
      [Unit]
      Description=Notify on %i failure
      After=syslog.target network-online.target remote-fs.target nss-lookup.target

      [Service]
      Type=oneshot
      ${lib.optionalString (
        ntfyEnabled && !fallback
      ) "LoadCredential=ntfy_token:${toString cfg.ntfy.tokenFile}"}
      ${lib.optionalString webhookEnabled "LoadCredential=webhook_url:${toString cfg.webhookUrlFile}"}
      ExecStart=${notifyScript} ${lib.optionalString fallback "--fallback "}%i
      StandardOutput=journal
      StandardError=journal
    '';
in
{
  options.services.systemd-failure-notify = {
    enable = lib.mkEnableOption "desktop notifications for systemd service failures";

    services = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Services whose failure is posted to the ntfy server (`ntfy.url`), or to
        `webhookUrlFile` when no ntfy server is set or it can't be reached.
      '';
      example = [
        "nginx"
        "postgresql"
      ];
    };

    fallbackServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Services the ntfy server depends on. Their failure is posted straight
        to `webhookUrlFile`, since the ntfy server may be down with them.
      '';
      example = [ "nginx" ];
    };

    ntfy = {
      url = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = "Topic URL on the self-hosted ntfy server.";
        example = "https://ntfy.example.ts.net/fleet";
      };
      tokenFile = lib.mkOption {
        type = with lib.types; nullOr path;
        default = null;
        description = "Runtime file holding the ntfy access token, passed as a systemd credential.";
        example = lib.literalExpression "config.sops.secrets.ntfy_token.path";
      };
    };

    source = lib.mkOption {
      type = lib.types.str;
      default = "system";
      description = "Notification source (lib/ntfy.nix) the messages are tagged with.";
    };

    unitSources = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Per-service overrides of `source`.";
      example = {
        restic-backups-local = "backups";
      };
    };

    webhookUrlFile = lib.mkOption {
      type = with lib.types; nullOr path;
      default = null;
      description = ''
        Optional runtime file containing an off-host webhook URL, normally the
        public ntfy.sh fallback topic. When set, the failure template posts a
        compact text notification to this URL using a systemd credential, so
        the URL is not rendered into the Nix store or process arguments.
      '';
      example = lib.literalExpression "config.sops.secrets.ntfy_fallback_url.path";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = ntfyEnabled == (cfg.ntfy.tokenFile != null);
        message = "services.systemd-failure-notify: ntfy.url and ntfy.tokenFile go together";
      }
      {
        assertion = cfg.fallbackServices == [ ] || webhookEnabled;
        message = "services.systemd-failure-notify.fallbackServices needs webhookUrlFile";
      }
      {
        assertion = lib.all (s: !(builtins.elem s cfg.services)) cfg.fallbackServices;
        message = "services.systemd-failure-notify: a service is either in services or in fallbackServices";
      }
    ];

    environment.systemPackages = with pkgs; [ libnotify ];

    # Template units for failure notifications
    systemd.units = {
      "notify-failure@.service".text = template { fallback = false; };
      "notify-failure-fallback@.service".text = template { fallback = true; };
    };

    # Attach OnFailure to specified services
    systemd.services = lib.mkMerge (
      map (serviceName: {
        "${serviceName}".onFailure = [ "notify-failure@${serviceName}.service" ];
      }) cfg.services
      ++ map (serviceName: {
        "${serviceName}".onFailure = [ "notify-failure-fallback@${serviceName}.service" ];
      }) cfg.fallbackServices
    );
  };
}
