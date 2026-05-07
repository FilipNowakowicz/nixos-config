{ config, lib, ... }:
let
  cfg = config.profiles.homeserverGcpNginx;
  certDir = "/var/lib/nginx/certs";
in
{
  options.profiles.homeserverGcpNginx = {
    enable = lib.mkEnableOption "homeserver-gcp nginx reverse proxy";

    fqdn = lib.mkOption {
      type = lib.types.str;
      description = "Fully-qualified domain name for the nginx virtual host and TLS certificate";
    };

    ingestHtpasswdFile = lib.mkOption {
      type = lib.types.path;
      description = "htpasswd file protecting the /obs/* observability ingest paths";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${certDir} 0750 root nginx -"
    ];

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;

      virtualHosts.${cfg.fqdn} = {
        forceSSL = true;
        sslCertificate = "${certDir}/homeserver-gcp.crt";
        sslCertificateKey = "${certDir}/homeserver-gcp.key";

        locations = {
          "/" = {
            proxyPass = "http://127.0.0.1:8222";
            proxyWebsockets = true;
          };

          "/grafana/" = {
            proxyPass = "http://127.0.0.1:3000";
            proxyWebsockets = true;
          };

          "/obs/loki/" = {
            proxyPass = "http://127.0.0.1:3100/";
            basicAuthFile = cfg.ingestHtpasswdFile;
          };

          "/obs/mimir/" = {
            proxyPass = "http://127.0.0.1:9009/";
            basicAuthFile = cfg.ingestHtpasswdFile;
          };

          "/obs/otlp/" = {
            proxyPass = "http://127.0.0.1:14318/";
            basicAuthFile = cfg.ingestHtpasswdFile;
          };
        };
      };
    };
  };
}
