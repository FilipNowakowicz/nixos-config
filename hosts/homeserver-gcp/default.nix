{
  config,
  inputs,
  hostMeta,
  pkgs,
  ...
}:
let
  inherit (hostMeta) tailnetFQDN;
in
{
  imports = [
    inputs.disko.nixosModules.disko
    ./hardware-configuration.nix
    ./disko.nix
    ./nginx.nix
    ./adguard.nix
    ./backups.nix
    ./status-page.nix
    ./audits.nix
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
    pkgs.kitty.terminfo
    pkgs.wezterm.terminfo
  ];

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
            # stay observable from inside the tailnet boundary. This host itself is
            # not a human Tailscale identity, so the healthy outcome is a denial.
            grafana-auth-boundary = {
              url = "https://${tailnetFQDN}/grafana/";
              expectedStatusCodes = [ 403 ];
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
      alertmanager_webhook_url = {
        owner = "mimir";
        group = "mimir";
      };
      observability_ingest_htpasswd = {
        owner = config.services.nginx.user;
        inherit (config.services.nginx) group;
      };
      restic_password = { };
      restic_repository = { };
      b2_credentials = { };
    };
  };

  # GCP VMs have no power supply subsystem; the power_supply collector fails to
  # initialize when /sys/class/power_supply is empty. Override the shared profile
  # list to drop it for this host only.
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
