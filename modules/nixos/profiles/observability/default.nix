{
  config,
  lib,
  ...
}:
let
  cfg = config.profiles.observability;
  mkFileDirective = path: "$__file{${toString path}}";
in
{
  imports = [
    ./alerts.nix
    ./backends.nix
    ./collectors.nix
    ./dashboards.nix
  ];

  options.profiles.observability = {
    enable = lib.mkEnableOption "LGTM observability profile";

    alertWebhookUrlFile = lib.mkOption {
      type = with lib.types; nullOr path;
      default = null;
      description = ''
        Path to a file containing the webhook URL for Alertmanager notifications
        (e.g. an ntfy.sh topic URL). Use a runtime secret path such as a sops
        secret; the URL is read by Alertmanager and is not rendered into the Nix
        store. When null (the default), alerts route to a null receiver so
        deployments without a configured URL keep working.
      '';
      example = lib.literalExpression "config.sops.secrets.alertmanager_webhook_url.path";
    };

    grafana = {
      enable = lib.mkEnableOption "Grafana";
      adminUser = lib.mkOption {
        type = lib.types.str;
        default = "admin";
        description = "Grafana admin username";
      };
      adminPasswordFile = lib.mkOption {
        type = with lib.types; nullOr path;
        default = null;
        description = "Path to a file containing the Grafana admin password. Loaded via the Grafana \$__file{} directive.";
        example = lib.literalExpression "config.sops.secrets.grafana_admin_password.path";
      };
      secretKeyFile = lib.mkOption {
        type = with lib.types; nullOr path;
        default = null;
        description = "Path to a file containing the Grafana secret key used for signing cookies and session tokens.";
        example = lib.literalExpression "config.sops.secrets.grafana_secret_key.path";
      };
    };

    ingestAuth = {
      username = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = "Username for HTTP Basic Auth when pushing metrics, logs, or traces to a remote ingest endpoint.";
        example = "telemetry";
      };
      passwordFile = lib.mkOption {
        type = with lib.types; nullOr path;
        default = null;
        description = "Path to a file containing the ingest password. Read directly by Prometheus for remote write; mounted as a group-readable secret for Alloy and the OTel collector.";
        example = lib.literalExpression "config.sops.secrets.ingest_password.path";
      };
      group = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = "Supplementary group granted read access to the ingest password secret. Prometheus, Alloy, and the OTel collector services are added to this group automatically.";
        example = "telemetry-ingest";
      };
      serviceEnvironmentFile = lib.mkOption {
        type = with lib.types; nullOr path;
        default = null;
        description = "Path to an environment file for the OTel collector service. Must contain BASICAUTH_PASSWORD=<secret>. Required when authenticated remote trace export is enabled.";
        example = lib.literalExpression "config.sops.templates.\"otel-env\".path";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.grafana.enable || cfg.grafana.adminPasswordFile != null;
        message = "profiles.observability.grafana.enable is true but grafana.adminPasswordFile is not set; Grafana will start without a configured admin credential.";
      }
    ];

    services.grafana = lib.mkIf cfg.grafana.enable {
      enable = true;
      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = 3000;
          domain = "localhost";
        };
        security = {
          admin_user = cfg.grafana.adminUser;
        }
        // lib.optionalAttrs (cfg.grafana.secretKeyFile != null) {
          secret_key = mkFileDirective cfg.grafana.secretKeyFile;
        }
        // lib.optionalAttrs (cfg.grafana.adminPasswordFile != null) {
          admin_password = mkFileDirective cfg.grafana.adminPasswordFile;
        };
      };
      provision = {
        enable = true;
        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "Mimir";
              type = "prometheus";
              access = "proxy";
              url = "http://127.0.0.1:9009/prometheus";
              uid = "mimir";
              isDefault = true;
            }
            {
              name = "Loki";
              type = "loki";
              access = "proxy";
              url = "http://127.0.0.1:3100";
              uid = "loki";
            }
            {
              name = "Tempo";
              type = "tempo";
              access = "proxy";
              url = "http://127.0.0.1:3200";
              uid = "tempo";
            }
          ];
        };
        dashboards.settings = {
          apiVersion = 1;
          providers = [
            {
              name = "default";
              orgId = 1;
              folder = "Overview";
              type = "file";
              # Dashboards are provisioned declaratively from the Nix store.
              # Lock down the UI so manual edits/deletions don't survive a
              # redeploy and silently diverge from the source of truth.
              disableDeletion = true;
              editable = false;
              options.path = "/etc/grafana-dashboards";
            }
          ];
        };
      };
    };

    systemd.tmpfiles.rules = lib.mkIf cfg.grafana.enable [
      "d /var/lib/grafana 0750 grafana grafana -"
    ];
  };
}
