{ config, lib, ... }:
let
  cfg = config.profiles.homeserverGcpNginx;
  gen = import ../../lib/generators.nix { inherit lib; };
  certDir = "/var/lib/nginx/certs";
  homepageDir = "/var/lib/homepage/public";
  homepageEventsTarget = "http://127.0.0.1:9273/";
  proxy = gen.nginx.proxyLocation;
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

    grafanaAuthRequestUrl = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      description = ''
        Optional localhost auth endpoint used by nginx auth_request before proxying
        /grafana/ traffic. When set, nginx forwards verified auth headers from the
        subrequest to Grafana.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${certDir} 0750 root nginx -"
      "d ${homepageDir} 0755 root nginx -"
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
          "/" = proxy {
            target = "http://127.0.0.1:8222";
            websockets = true;
          };

          "= /notifications/hub" = proxy {
            target = "http://127.0.0.1:8222";
            websockets = true;
          };

          "/grafana/" = proxy {
            target = "http://127.0.0.1:3000";
            websockets = true;
            extraConfig = lib.optionalString (cfg.grafanaAuthRequestUrl != null) ''
              auth_request /_grafana_auth;
              auth_request_set $grafana_user $upstream_http_x_auth_request_user;
              auth_request_set $grafana_name $upstream_http_x_auth_request_name;
              auth_request_set $grafana_email $upstream_http_x_auth_request_email;
              auth_request_set $grafana_role $upstream_http_x_auth_request_role;
              proxy_set_header X-WEBAUTH-USER $grafana_user;
              proxy_set_header X-WEBAUTH-NAME $grafana_name;
              proxy_set_header X-WEBAUTH-EMAIL $grafana_email;
              proxy_set_header X-WEBAUTH-ROLE $grafana_role;
            '';
          };

          "= /_grafana_auth" = lib.mkIf (cfg.grafanaAuthRequestUrl != null) {
            proxyPass = cfg.grafanaAuthRequestUrl;
            extraConfig = ''
              internal;
              proxy_pass_request_body off;
              proxy_set_header Content-Length "";
              proxy_set_header X-Tailscale-Remote-Addr $remote_addr;
              proxy_set_header X-Original-URI $request_uri;
            '';
          };

          "= /home" = {
            return = "301 /home/";
          };

          "= /home/index.html" = {
            alias = "${homepageDir}/index.html";
            extraConfig = ''
              add_header Cache-Control "no-store" always;
            '';
          };

          "~ ^/home/src/(?<asset>.+\\.[0-9a-f]{10}\\.(?:js|css))$" = {
            alias = "${homepageDir}/src/$asset";
            extraConfig = ''
              add_header Cache-Control "public, max-age=31536000, immutable" always;
            '';
          };

          "/home/" = {
            alias = "${homepageDir}/";
            extraConfig = ''
              try_files $uri $uri/ /home/index.html;
            '';
          };

          "= /home/status.json" = {
            alias = "${homepageDir}/status.json";
            extraConfig = ''
              default_type application/json;
              add_header Cache-Control "no-store";
            '';
          };

          "= /home/status.events" = {
            proxyPass = homepageEventsTarget;
            extraConfig = ''
              proxy_http_version 1.1;
              proxy_set_header Connection "";
              proxy_buffering off;
              proxy_cache off;
              add_header Cache-Control "no-store";
              add_header X-Accel-Buffering "no";
            '';
          };

          "= /home/status.svg" = {
            alias = "${homepageDir}/status.svg";
            extraConfig = ''
              default_type image/svg+xml;
              add_header Cache-Control "no-store";
            '';
          };

          "/obs/" = {
            return = "404";
          };

          "= /obs/loki/loki/api/v1/push" = proxy {
            target = "http://127.0.0.1:3100/loki/api/v1/push";
            basicAuthFile = cfg.ingestHtpasswdFile;
          };

          "= /obs/mimir/api/v1/push" = proxy {
            target = "http://127.0.0.1:9009/api/v1/push";
            basicAuthFile = cfg.ingestHtpasswdFile;
          };

          "= /obs/otlp/v1/traces" = proxy {
            target = "http://127.0.0.1:14318/v1/traces";
            basicAuthFile = cfg.ingestHtpasswdFile;
          };
        };
      };
    };
  };
}
