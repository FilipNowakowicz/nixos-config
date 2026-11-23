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
  hostDriftInventory = {
    schemaVersion = 1;
    hosts = [
      {
        inherit (hostMeta) name;
        deployable = true;
        deployUser = hostMeta.deploy.sshUser or "user";
        drift = {
          tailscaleTag = hostMeta.tailscale.tag or null;
          inherit tailnetFQDN;
          tcpPorts = config.networking.firewall.interfaces.tailscale0.allowedTCPPorts or [ ];
          expectedExtraTCPPorts = [
            80
            22000
          ];
          strictTCPPortSet = true;
          systemdUnits = lib.filter (unit: unit != "") [
            (lib.optionalString config.services.openssh.enable "sshd.service")
            (lib.optionalString config.services.tailscale.enable "tailscaled.service")
            (lib.optionalString (config.services.nginx.enable or false) "nginx.service")
            (lib.optionalString (config.services.adguardhome.enable or false) "adguardhome.service")
            (lib.optionalString (config.services.grafana.enable or false) "grafana.service")
            (lib.optionalString (config.services.loki.enable or false) "loki.service")
            (lib.optionalString config.services.prometheus.enable "prometheus.service")
            (lib.optionalString config.services.prometheus.alertmanager.enable "alertmanager.service")
          ];
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
    ./adguard.nix
    ./backups.nix
    ./restore-drill.nix
    ./heartbeat.nix
    ./status-page.nix
    ./audits.nix
    ./hardening.nix
    ./github-runner.nix
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
    observability = {
      enable = true;
      alertWebhookUrlFile = config.sops.secrets.alertmanager_webhook_url.path;
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
        };
      };
    };

    homeserverGcpNginx = {
      enable = true;
      fqdn = tailnetFQDN;
      ingestHtpasswdFile = config.sops.secrets.observability_ingest_htpasswd.path;
      grafanaAuthRequestUrl = "http://127.0.0.1:3180/auth";
    };
  };

  services = {
    # gce-server.nix enables Tailscale with --reset.
    tailscale.authKeyFile = config.sops.secrets.tailscale_auth_key.path;

    systemd-failure-notify = {
      enable = true;
      webhookUrlFile = config.sops.secrets.alertmanager_webhook_url.path;
      services = [
        "alertmanager"
        "prometheus"
        "prometheus-node-exporter"
        "nginx"
        "tailscaled"
        "heartbeat-ping"
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
      alertmanager_webhook_url = {
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
      # Fine-grained PAT used only to register the GitHub Actions deploy runner.
      # Populate with `sops hosts/homeserver-gcp/secrets/secrets.yaml` before
      # enabling github-runner-homeserver-deploy.service.
      github_runner_homeserver_deploy_token = { };
      # SSH private key the deploy runner uses to reach this host. The runner
      # lives on homeserver-gcp and the deploy workflow runs deploy-rs +
      # systemctl checks over `ssh user@homeserver-gcp` (a self-connection), so
      # the runner's `user` account needs an authorized identity. Placed at the
      # default identity path; the matching public key is authorized for `user`
      # in ./github-runner.nix.
      homeserver_selfdeploy_ssh_key = {
        path = "/home/user/.ssh/id_ed25519";
        owner = "user";
        mode = "0600";
      };
    };
  };

  # Static group bridging the root-owned alertmanager_webhook_url secret to the
  # Alertmanager service user. systemd adds the dynamic user to this group at start.
  users.groups.alertmanager-webhook = { };
  systemd.services.alertmanager.serviceConfig.SupplementaryGroups = [ "alertmanager-webhook" ];

  services.prometheus.retentionTime = "30d";
  services.prometheus.extraFlags = [ "--web.enable-remote-write-receiver" ];

  users.users.user = {
    hashedPasswordFile = config.sops.secrets.user_password.path;
    # Private half is only the HOMESERVER_DEPLOY_SSH_KEY GitHub secret, used by
    # the deploy workflow's tag:ci job. Root-equivalent through deploy-rs.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMwEwzG2ZPb8BzPhYq8QYFCQq2tqsviTbO3qJNzHcwRl homeserver-gcp-ci-deploy"
    ];
  };
}
