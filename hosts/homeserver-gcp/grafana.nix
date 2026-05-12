{
  lib,
  pkgs,
  hostMeta,
  ...
}:
let
  inherit (hostMeta) tailnetFQDN;
  grafanaTailscaleAuth = pkgs.buildGoModule {
    pname = "grafana-tailscale-auth";
    version = "0.1.0";
    src = ./grafana-tailscale-auth;
    vendorHash = null;
  };
in
{
  systemd.services = {
    grafana-tailscale-auth = {
      description = "Resolve Tailscale identities for Grafana auth proxy";
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        LISTEN_ADDR = "127.0.0.1:3180";
        TAILSCALE_BIN = "${pkgs.tailscale}/bin/tailscale";
        DEFAULT_ROLE = "Viewer";
        ROLE_MAP_JSON = builtins.toJSON { };
      };
      serviceConfig = {
        ExecStart = "${grafanaTailscaleAuth}/bin/grafana-tailscale-auth";
        Restart = "on-failure";
        RestartSec = 2;
        DynamicUser = true;
        ReadWritePaths = [ "/var/run/tailscale" ];
        BindPaths = [ "/var/run/tailscale:/var/run/tailscale" ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
    };

    nginx = {
      after = [
        "tailscale-cert.service"
        "grafana-tailscale-auth.service"
      ];
      requires = [
        "tailscale-cert.service"
        "grafana-tailscale-auth.service"
      ];
    };
  };

  services.grafana.settings = {
    analytics = {
      reporting_enabled = false;
      check_for_updates = false;
      check_for_plugin_updates = false;
    };
    server = {
      domain = lib.mkForce tailnetFQDN;
      root_url = "https://%(domain)s/grafana/";
      serve_from_sub_path = true;
    };
    "auth.proxy" = {
      enabled = true;
      header_name = "X-WEBAUTH-USER";
      header_property = "email";
      auto_sign_up = true;
      sync_ttl = 0;
      whitelist = "127.0.0.1";
      headers = "Name:X-WEBAUTH-NAME Role:X-WEBAUTH-ROLE Email:X-WEBAUTH-EMAIL";
    };
  };
}
