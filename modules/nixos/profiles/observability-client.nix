# Client-side observability: ships metrics, logs, and traces to a remote ingest stack.
# Hosts import this module and set remoteEndpoint.host; the module wires all three
# collectors and creates the sops template expected by the OTel collector.
# The host must still declare sops.secrets.observability_ingest_password.
{ config, lib, ... }:
let
  cfg = config.profiles.observability-client;
in
{
  options.profiles.observability-client = {
    enable = lib.mkEnableOption "remote observability client (metrics, logs, traces)";

    remoteEndpoint.host = lib.mkOption {
      type = lib.types.str;
      description = "Tailscale FQDN of the host running the observability ingest stack. Used to construct remote write, log push, and trace export URLs under /obs/*.";
      example = "homeserver-gcp.example.ts.net";
    };

    ingestAuth.username = lib.mkOption {
      type = lib.types.str;
      default = "telemetry";
      description = "Username for authenticated push; must match the server htpasswd entry";
    };

    ingestAuth.group = lib.mkOption {
      type = lib.types.str;
      default = "telemetry-ingest";
      description = "Local group allowed to read the ingest password secret.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${cfg.ingestAuth.group} = { };

    sops.secrets.observability_ingest_password = {
      inherit (cfg.ingestAuth) group;
      mode = "0440";
    };

    sops.templates."otel-env" = {
      content = "BASICAUTH_PASSWORD=${config.sops.placeholder.observability_ingest_password}";
      mode = "0400";
    };

    profiles.observability = {
      enable = true;
      collectors = {
        metrics = {
          enable = true;
          remoteWriteURL = "https://${cfg.remoteEndpoint.host}/obs/mimir/api/v1/push";
        };
        logs = {
          enable = true;
          pushURL = "https://${cfg.remoteEndpoint.host}/obs/loki/loki/api/v1/push";
        };
        traces = {
          enable = true;
          exportURL = "https://${cfg.remoteEndpoint.host}/obs/otlp/v1/traces";
        };
      };
      ingestAuth = {
        inherit (cfg.ingestAuth) username group;
        passwordFile = config.sops.secrets.observability_ingest_password.path;
        serviceEnvironmentFile = config.sops.templates."otel-env".path;
      };
    };
  };
}
