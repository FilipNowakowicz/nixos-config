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
        name = "homeserver-gcp";
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
            (lib.optionalString (config.services.vaultwarden.enable or false) "vaultwarden.service")
            (lib.optionalString (config.services.adguardhome.enable or false) "adguardhome.service")
            (lib.optionalString (config.services.grafana.enable or false) "grafana.service")
            (lib.optionalString (config.services.loki.enable or false) "loki.service")
            (lib.optionalString (config.services.mimir.enable or false) "mimir.service")
            (lib.optionalString (config.services.tempo.enable or false) "tempo.service")
          ];
        };
      }
    ];
  };
in
{
  imports = [
    inputs.disko.nixosModules.disko
    ./hardware-configuration.nix
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
    ../../modules/nixos/profiles/base.nix
    ../../modules/nixos/profiles/machine-common.nix
    ../../modules/nixos/profiles/security.nix
    ../../modules/nixos/profiles/sops-base.nix
    ../../modules/nixos/profiles/user.nix
  ];

  system = {
    stateVersion = "24.11";
  };

  # Broad passwordless sudo: deploy-rs needs it for activation. SSH access to
  # this target is therefore root-equivalent; keep SSH Tailscale-scoped and
  # key-only.
  security.sudo.wheelNeedsPassword = false;

  nix = {
    settings.trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "main.local:fSo1pk+WU1RU7vpv+GTbzldKn4MMtBS46vQasXJ2oeQ="
    ];
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
  };

  environment.systemPackages = [
    # Keep common client terminal definitions available over SSH without pulling
    # every terminfo package into the server closure.
    pkgs.alacritty.terminfo
    pkgs.foot.terminfo
    pkgs.gawk
    pkgs.jq
    pkgs.kitty.terminfo
    pkgs.wezterm.terminfo
  ];

  environment.etc."host-drift-inventory.json".text = builtins.toJSON hostDriftInventory;

  networking = {
    hostName = "homeserver-gcp";
    firewall = {
      checkReversePath = "loose";
      interfaces.tailscale0.allowedTCPPorts = [
        22
        443
      ];
    };
  };

  boot = {
    # This host does not use ZFS. Set the new 26.11 default explicitly to avoid
    # the evaluation warning and make the intent stable across upgrades.
    zfs.forceImportRoot = false;
    loader.timeout = 1;
    kernelParams = [
      "console=tty1"
      "console=ttyS0,115200n8"
      "systemd.journald.forward_to_console=1"
    ];
  };

  profiles = {
    # deploy-rs remoteBuild connects as `user`; trust it so remote builds do not
    # trip restricted-setting warnings from the daemon.
    nix.extraTrustedUsers = [ "user" ];

    observability = {
      enable = true;
      alertWebhookUrlFile = config.sops.secrets.alertmanager_webhook_url.path;
      grafana = {
        enable = true;
        adminPasswordFile = config.sops.secrets.grafana_admin_password.path;
        secretKeyFile = config.sops.secrets.grafana_secret_key.path;
      };
      loki.enable = true;
      tempo.enable = true;
      mimir.enable = true;
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
        traces.enable = true;
        blackbox = {
          enable = true;
          probes = {
            vaultwarden-root = {
              url = "https://${tailnetFQDN}/";
              expectedStatusCodes = [
                200
                301
                302
              ];
            };

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
    openssh = {
      enable = true;
      openFirewall = false;
    };

    tailscale = {
      enable = true;
      openFirewall = true;
      authKeyFile = config.sops.secrets.tailscale_auth_key.path;
    };

    systemd-failure-notify = {
      enable = true;
      webhookUrlFile = config.sops.secrets.alertmanager_webhook_url.path;
      services = [
        "mimir"
        "prometheus"
        "prometheus-node-exporter"
        "nginx"
        "tailscaled"
        "heartbeat-ping"
      ];
    };

    journald.extraConfig = ''
      ForwardToConsole=yes
      MaxLevelConsole=info
    '';

    hardened = {
      nginx = {
        extraConfig = {
          CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";
          AmbientCapabilities = "CAP_NET_BIND_SERVICE";
          ReadWritePaths = [
            "/var/cache/nginx"
            "/var/log/nginx"
            "/var/lib/nginx/certs"
          ];
        };
      };

      vaultwarden = {
        extraConfig = {
          CapabilityBoundingSet = "";
          AmbientCapabilities = "";
          ReadWritePaths = [ "/var/lib/vaultwarden" ];
        };
      };
    };

    vaultwarden = {
      enable = true;
      config = {
        ROCKET_ADDRESS = "127.0.0.1";
        ROCKET_PORT = 8222;
        SIGNUPS_ALLOWED = false;
        INVITATIONS_ALLOWED = false;
        # ADMIN_TOKEN intentionally omitted — the /admin endpoint is disabled.
        DOMAIN = "https://${tailnetFQDN}";
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
      # mimir runs as a systemd DynamicUser, so the "mimir" user/group only
      # exist while the unit is running (via nss-systemd) and cannot be resolved
      # during activation, when setupSecrets runs with mimir stopped. Own the
      # secret by root and grant read access through a static supplementary
      # group the mimir unit joins: sops-install-secrets resolves it at
      # activation, and mimir still reads the webhook URL at runtime.
      alertmanager_webhook_url = {
        mode = "0440";
        group = "mimir-webhook";
      };
      observability_ingest_htpasswd = {
        owner = config.services.nginx.user;
        inherit (config.services.nginx) group;
      };
      restic_password = { };
      restic_repository = { };
      b2_credentials = { };
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
  # mimir DynamicUser. systemd adds the dynamic user to this group at start.
  users.groups.mimir-webhook = { };
  systemd.services.mimir.serviceConfig.SupplementaryGroups = [ "mimir-webhook" ];

  # GCP VMs have no power supply subsystem; the powersupplyclass collector fails
  # to initialize when /sys/class/power_supply is empty. Override the shared
  # profile list to drop it for this host only.
  services.prometheus.exporters.node.enabledCollectors = pkgs.lib.mkForce [
    "cpu"
    "filesystem"
    "loadavg"
    "meminfo"
    "netdev"
    "systemd"
    "textfile"
    "thermal_zone"
  ];

  users.users.user = {
    home = "/home/user";
    hashedPasswordFile = config.sops.secrets.user_password.path;
  };
}
