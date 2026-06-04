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
  systemd = {
    services.tailscale-cert = {
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
        ${pkgs.tailscale}/bin/tailscale cert \
          --cert-file /var/lib/tailscale/certs/homeserver-gcp.crt \
          --key-file /var/lib/tailscale/certs/homeserver-gcp.key \
          ${tailnetFQDN}
        # /var/lib/tailscale is root:root 700; copy certs to a path nginx can read
        install -m 644 /var/lib/tailscale/certs/homeserver-gcp.crt /var/lib/nginx/certs/homeserver-gcp.crt
        install -m 640 -g nginx /var/lib/tailscale/certs/homeserver-gcp.key /var/lib/nginx/certs/homeserver-gcp.key
        if ${pkgs.systemd}/bin/systemctl is-active --quiet nginx.service; then
          ${pkgs.systemd}/bin/systemctl --no-block reload nginx.service
        fi
      '';
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = 120;
      };
    };

    timers.tailscale-cert = timer {
      schedule = "daily";
      jitter = "1h";
    };

    tmpfiles.rules = [
      "d /var/lib/tailscale/certs 0750 root root -"
      "d /var/lib/nginx/certs 0750 root nginx -"
    ];
  };

  services.hardened.tailscale-cert.extraConfig = {
    ProtectHome = false;
    ReadWritePaths = [
      "/var/lib/tailscale"
      "/var/lib/nginx/certs"
    ];
    RestrictAddressFamilies = [ "AF_UNIX" ];
    # The cert script chgrps the private key to the nginx group
    # (`install -g nginx`) so nginx can read it. chgrp needs CAP_CHOWN, which the
    # hardened baseline otherwise strips (CapabilityBoundingSet=""). Without this
    # the service fails at runtime ("install: cannot change ownership … Operation
    # not permitted"), nginx's `requires=` goes unmet, and nginx will not start.
    CapabilityBoundingSet = [ "CAP_CHOWN" ];
    AmbientCapabilities = [ "CAP_CHOWN" ];
  };
}
