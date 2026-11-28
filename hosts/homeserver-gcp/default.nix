{
  config,
  inputs,
  hostMeta,
  lib,
  pkgs,
  ...
}:
let
  inherit (hostMeta) tailnetFQDN;
  driftLib = import ../../lib/drift.nix { inherit lib; };
  ntfy = import ../../lib/ntfy.nix { };
  # Read by scripts/deploy-homeserver.sh; the same facts feed the fleet
  # inventory through lib/inventory-data.nix.
  hostDriftInventory = {
    schemaVersion = 1;
    hosts = [
      {
        inherit (hostMeta) name;
        deployable = true;
        deployUser = hostMeta.deploy.sshUser;
        drift = {
          tailscaleTag = hostMeta.tailscale.tag or null;
          inherit tailnetFQDN;
          tcpPorts = config.networking.firewall.interfaces.tailscale0.allowedTCPPorts or [ ];
          inherit (config.profiles.drift) expectedExtraTCPPorts;
          strictTCPPortSet = true;
          systemdUnits = driftLib.systemdUnits config;
        };
      }
    ];
  };
in
{
  imports = [
    inputs.disko.nixosModules.disko
    ./disko.nix
    ./nginx.nix
    ./ntfy.nix
    ./adguard.nix
    ./backups.nix
    ./restore-drill.nix
    ./heartbeat.nix
    ./tailnet-presence.nix
    ./audits.nix
    ./hardening.nix
    ./build-resource-limits.nix
    ./tailscale-cert.nix
    ./grafana.nix
    ./dashboards.nix
    ../../modules/nixos/profiles/gce-server.nix
  ];

  system = {
    stateVersion = "24.11";
  };

  # gce-server.nix grants broad passwordless sudo for deploy-rs activation, so
  # SSH access here is root-equivalent; keep it Tailscale-scoped and key-only.

  # curl comes from the base profile. jq stays at system level for root and
  # for checks run over SSH, which don't get Home Manager's PATH.
  environment.systemPackages = [
    pkgs.dig
    pkgs.gawk
    pkgs.jq
  ];

  environment.etc."host-drift-inventory.json".text = builtins.toJSON hostDriftInventory;

  networking = {
    hostName = "homeserver-gcp";
    firewall.interfaces.tailscale0.allowedTCPPorts = [
      22
      443
    ];
  };

  profiles = {
    drift = {
      trackedServices = [
        "adguard"
        "nginx"
        "grafana"
        "loki"
        "prometheus"
        "alertmanager"
        "ntfy"
      ];
      expectedExtraTCPPorts = [
        80 # nginx HTTP->HTTPS redirect vhost (binds 0.0.0.0; tailnet-firewalled)
      ];
    };
    observability = {
      enable = true;
      # Alerts go to the local ntfy server, formatted by its fleet-alert template.
      alertWebhookUrl = "${ntfy.localTopicUrl}?template=fleet-alert&tags=${ntfy.tags "homeserver"}";
      alertWebhookBearerTokenFile = config.sops.secrets.ntfy_token_homeserver.path;
      watchdogUrlFile = config.sops.secrets.alertmanager_watchdog_url.path;
      grafana = {
        enable = true;
        adminPasswordFile = config.sops.secrets.grafana_admin_password.path;
        secretKeyFile = config.sops.secrets.grafana_secret_key.path;
      };
      loki.enable = true;
      alerts.enable = true;
      collectors = {
        metrics.enable = true;
        logs.enable = true;
        audit.enable = true;
        audit.extraSources.nginx = {
          matches = "SYSLOG_IDENTIFIER=nginx";
          eventType = "http";
          scope = "edge-access";
          formatAsJson = true;
        };
        blackbox = {
          enable = true;
          probes = {
            # Probe Grafana through nginx so auth_request and upstream routing both
            # stay observable from inside the tailnet boundary. The auth helper
            # maps tailnet node identities to the default Viewer role unless a
            # host-local role map promotes them, so a healthy probe reaches
            # Grafana successfully.
            grafana-auth-boundary = {
              url = "https://${tailnetFQDN}/grafana/";
              expectedStatusCodes = [ 200 ];
            };
          };
          # A real external name through AdGuard's tailnet address: catches a
          # hung AdGuard and failing upstreams, not only a failed unit.
          dnsProbes.adguard = {
            target = "${hostMeta.tailscale.ip4}:53";
            queryName = "cloudflare.com";
          };
        };
      };
    };

    homeserverGcpNginx = {
      enable = true;
      fqdn = tailnetFQDN;
      ingestHtpasswdFile = config.sops.secrets.observability_ingest_htpasswd.path;
      grafanaAuthRequestUrl = "http://127.0.0.1:3180/auth";
    };

    homeserverGcpNtfy = {
      enable = true;
      fqdn = tailnetFQDN;
      phonePasswordFile = config.sops.secrets.ntfy_phone_password.path;
      tokenFiles = {
        main = config.sops.secrets.ntfy_token_main.path;
        builder = config.sops.secrets.ntfy_token_builder.path;
        homeserver = config.sops.secrets.ntfy_token_homeserver.path;
      };
      # main subscribes and publishes; the builder and this host only publish.
      tokenAccess = {
        main = "rw";
        builder = "wo";
        homeserver = "wo";
      };
    };
  };

  services = {
    # gce-server.nix enables Tailscale with --reset and, from the registry's
    # exitNodeCanProvide, advertises this host as an opt-in exit node.
    tailscale.authKeyFile = config.sops.secrets.tailscale_auth_key.path;

    # Failures of the units the ntfy path depends on, and of the alerting
    # and reachability stack itself, go straight to the public ntfy.sh
    # fallback topic. The rest post to the local ntfy server, falling back to
    # the public topic if it is down.
    systemd-failure-notify = {
      enable = true;
      source = "homeserver";
      ntfy = {
        url = ntfy.localTopicUrl;
        tokenFile = config.sops.secrets.ntfy_token_homeserver.path;
      };
      webhookUrlFile = config.sops.secrets.ntfy_fallback_url.path;
      services = [
        "prometheus"
        "prometheus-node-exporter"
      ];
      fallbackServices = [
        "alertmanager"
        "heartbeat-ping"
        "nginx"
        "ntfy-sh"
        "tailscaled"
      ];
    };

    hardened = {
      nginx = {
        extraConfig = {
          CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";
          AmbientCapabilities = "CAP_NET_BIND_SERVICE";
          ReadWritePaths = [
            "/var/cache/nginx"
            "/var/log/nginx"
          ];
        };
      };
    };
  };

  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    secrets = {
      user_password.neededForUsers = true;
      tailscale_auth_key = { };
      grafana_admin_password.owner = "grafana";
      grafana_secret_key.owner = "grafana";
      # Public ntfy.sh topic for failures the local ntfy server cannot report.
      # Read by systemd-failure-notify as a root-loaded credential.
      ntfy_fallback_url = { };
      # Alertmanager sends it as a bearer token; systemd-failure-notify loads
      # it as a credential.
      ntfy_token_homeserver = {
        mode = "0440";
        group = "alertmanager-webhook";
      };
      # Loaded by ntfy-sh.service as credentials to provision its users.
      ntfy_token_main = { };
      ntfy_token_builder = { };
      ntfy_phone_password = { };
      # Ping URL of the healthchecks.io check behind the always-firing
      # Watchdog alert. Alertmanager reads it at send time, so the loopback
      # placeholder only yields failed sends until the real URL is set with
      # `bash scripts/rotate-secret.sh set` (see the Alert delivery gotcha in
      # ./CLAUDE.md).
      alertmanager_watchdog_url = {
        mode = "0440";
        group = "alertmanager-webhook";
      };
      observability_ingest_htpasswd = {
        owner = config.services.nginx.user;
        inherit (config.services.nginx) group;
      };
      # External dead-man's-switch ping URL (e.g. a healthchecks.io check URL).
      # Read at runtime by heartbeat-ping.service via LoadCredential; populate
      # with `sops hosts/homeserver-gcp/secrets/secrets.yaml` before deploying.
      heartbeat_ping_url = { };
    };
  };

  # Static group bridging the root-owned ntfy_token_homeserver and watchdog secrets to the
  # Alertmanager service user. systemd adds the dynamic user to this group at start.
  users.groups.alertmanager-webhook = { };
  systemd.services.alertmanager.serviceConfig.SupplementaryGroups = [ "alertmanager-webhook" ];

  services.prometheus.retentionTime = "30d";
  services.prometheus.extraFlags = [ "--web.enable-remote-write-receiver" ];

  users.users.${config.profiles.primaryUser} = {
    hashedPasswordFile = config.sops.secrets.user_password.path;
    # Private half is only the HOMESERVER_DEPLOY_SSH_KEY GitHub secret, used by
    # the deploy workflow's tag:ci job. Root-equivalent through deploy-rs.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMwEwzG2ZPb8BzPhYq8QYFCQq2tqsviTbO3qJNzHcwRl homeserver-gcp-ci-deploy"
    ];
  };
}
