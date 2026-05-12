{
  lib,
  pkgs,
  hostMeta,
  ...
}:
let
  inherit (hostMeta) tailnetFQDN;
  gen = import ../../lib/generators.nix { inherit lib; };
  inherit (gen.systemd) timer;
in
{
  systemd.services.tailscale-cert = {
    description = "Fetch TLS certificate from Tailscale";
    wantedBy = [ "multi-user.target" ];
    after = [
      "tailscaled.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    script = ''
      for attempt in {1..60}; do
        ${pkgs.tailscale}/bin/tailscale status > /dev/null 2>&1 && break
        [ $attempt -lt 60 ] && sleep 1
      done
      mkdir -p /var/lib/tailscale/certs
      ${pkgs.tailscale}/bin/tailscale cert \
        --cert-file /var/lib/tailscale/certs/homeserver-gcp.crt \
        --key-file /var/lib/tailscale/certs/homeserver-gcp.key \
        ${tailnetFQDN}
      # /var/lib/tailscale is root:root 700; copy certs to a path nginx can read
      mkdir -p /var/lib/nginx/certs
      install -m 644 /var/lib/tailscale/certs/homeserver-gcp.crt /var/lib/nginx/certs/homeserver-gcp.crt
      install -m 640 -g nginx /var/lib/tailscale/certs/homeserver-gcp.key /var/lib/nginx/certs/homeserver-gcp.key
      if ${pkgs.systemd}/bin/systemctl is-active --quiet nginx.service; then
        ${pkgs.systemd}/bin/systemctl reload nginx.service
      fi
    '';
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = 120;
    };
  };

  systemd.timers.tailscale-cert = timer {
    schedule = "daily";
    jitter = "1h";
  };

  services.hardened.tailscale-cert.extraConfig = {
    ProtectHome = false;
    ReadWritePaths = [
      "/var/lib/tailscale"
      "/var/lib/nginx/certs"
    ];
    RestrictAddressFamilies = [ "AF_UNIX" ];
  };
}
