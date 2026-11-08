{ config, lib, ... }:
let
  cfg = config.profiles.observability-client;
  endpointURL = path: "${cfg.remoteEndpoint.scheme}://${cfg.remoteEndpoint.host}${path}";
in
{
  options.profiles.observability-client = {
    enable = lib.mkEnableOption "remote observability client (metrics, logs)";

    remoteEndpoint = {
      scheme = lib.mkOption {
        type = lib.types.enum [
          "http"
          "https"
        ];
        default = "https";
        description = "Scheme used for remote observability ingest URLs.";
      };

      host = lib.mkOption {
        type = lib.types.str;
        description = "DNS name of the host running the observability ingest stack.";
        example = "observability.example.ts.net";
      };

      metricsPath = lib.mkOption {
        type = lib.types.str;
        default = "/obs/prometheus/api/v1/write";
        description = "Ingress path for Prometheus remote write.";
      };

      logsPath = lib.mkOption {
        type = lib.types.str;
        default = "/obs/loki/loki/api/v1/push";
        description = "Ingress path for Loki log pushes.";
      };

    };

    ingestAuth = {
      username = lib.mkOption {
        type = lib.types.str;
        default = "telemetry";
        description = "Username for authenticated pushes.";
      };

      group = lib.mkOption {
        type = lib.types.str;
        default = "telemetry-ingest";
        description = "Local group allowed to read the ingest password secret.";
      };

      passwordFile = lib.mkOption {
        type = with lib.types; nullOr path;
        default = null;
        description = "Path to a file containing the ingest password. Set this directly to avoid any sops-nix dependency.";
        example = lib.literalExpression "config.age.secrets.observability-ingest-password.path";
      };

    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (path: lib.hasPrefix "/" path) [
          cfg.remoteEndpoint.metricsPath
          cfg.remoteEndpoint.logsPath
        ];
        message = "profiles.observability-client remoteEndpoint paths must begin with '/'.";
      }
      {
        assertion = cfg.ingestAuth.passwordFile != null;
        message = "profiles.observability-client requires ingestAuth.passwordFile.";
      }
    ];

    users.groups.${cfg.ingestAuth.group} = { };

    profiles.observability = {
      enable = true;
      collectors = {
        metrics = {
          enable = true;
          remoteWriteURL = endpointURL cfg.remoteEndpoint.metricsPath;
        };
        logs = {
          enable = true;
          pushURL = endpointURL cfg.remoteEndpoint.logsPath;
        };
        audit.enable = true;
      };
      ingestAuth = {
        inherit (cfg.ingestAuth)
          username
          group
          passwordFile
          ;
      };
    };
  };
}
