{
  config,
  lib,
  pkgs,
  inputs,
  hostMeta,
  ...
}:
let
  inherit (hostMeta) tailnetFQDN;
  dash = import ../../lib/dashboards.nix;
  textfileDir = "/var/lib/node-exporter-textfiles";
in
{
  imports = [
    inputs.disko.nixosModules.disko
    ./hardware-configuration.nix
    ./disko.nix
    ./nginx.nix
    ./adguard.nix
    ../../modules/nixos/profiles/base.nix
    ../../modules/nixos/profiles/machine-common.nix
    ../../modules/nixos/profiles/security.nix
    ../../modules/nixos/profiles/sops-base.nix
    ../../modules/nixos/profiles/user.nix
  ];

  systemd = {
    services = {
      restic-backups-b2 = {
        serviceConfig.ExecStartPost = pkgs.writeShellScript "restic-backup-metrics" ''
          tmp=${textfileDir}/restic_backup.prom.tmp
          {
            echo "# HELP restic_last_backup_timestamp_seconds Unix timestamp of last successful restic backup"
            echo "# TYPE restic_last_backup_timestamp_seconds gauge"
            echo "restic_last_backup_timestamp_seconds $(date +%s)"
          } > "$tmp"
          mv "$tmp" ${textfileDir}/restic_backup.prom
        '';
      };

      restic-check-b2 = {
        description = "Restic B2 repository integrity check";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        environment = {
          RESTIC_REPOSITORY = "b2:filipnowakowicz-gcp:";
          RESTIC_PASSWORD_FILE = config.sops.secrets.restic_password.path;
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.restic}/bin/restic check --read-data-subset=1G";
          ExecStartPost = pkgs.writeShellScript "restic-check-metrics" ''
            tmp=${textfileDir}/restic_check.prom.tmp
            {
              echo "# HELP restic_last_check_timestamp_seconds Unix timestamp of last successful restic integrity check"
              echo "# TYPE restic_last_check_timestamp_seconds gauge"
              echo "restic_last_check_timestamp_seconds $(date +%s)"
            } > "$tmp"
            mv "$tmp" ${textfileDir}/restic_check.prom
          '';
          EnvironmentFile = config.sops.secrets.b2_credentials.path;
        };
      };

      tailscale-cert = {
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

      nginx = {
        after = [ "tailscale-cert.service" ];
        requires = [ "tailscale-cert.service" ];
      };
    };

    timers.restic-check-b2 = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
        RandomizedDelaySec = "2h";
      };
    };

    timers.tailscale-cert = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };

  system = {
    stateVersion = "24.11";

    activationScripts = {
      # On first boot the SSH host key doesn't exist yet, so sops can't decrypt secrets.
      # This activation script fetches the pre-baked key from GCE instance metadata
      # (injected by OpenTofu at VM creation) before sops-nix runs.
      injectGceSshHostKey = ''
        if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
          mkdir -p /etc/ssh
          _tmpkey=$(${pkgs.coreutils}/bin/mktemp -p /run)
          _fetched=0
          for _i in 1 2 3 4 5; do
            if ${pkgs.curl}/bin/curl -sf --max-time 5 \
              -H "Metadata-Flavor: Google" \
              "http://metadata.google.internal/computeMetadata/v1/instance/attributes/ssh-host-key-b64" \
              2>/dev/null \
              | ${pkgs.coreutils}/bin/base64 -d > "$_tmpkey" 2>/dev/null; then
              _fetched=1
              break
            fi
            sleep 2
          done
          if [ "$_fetched" = "1" ] && [ -s "$_tmpkey" ]; then
            install -m 600 "$_tmpkey" /etc/ssh/ssh_host_ed25519_key
            ${pkgs.openssh}/bin/ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key > /etc/ssh/ssh_host_ed25519_key.pub
            chmod 644 /etc/ssh/ssh_host_ed25519_key.pub
          fi
          rm -f "$_tmpkey"
        fi
      '';

      setupSecrets.deps = lib.mkAfter [ "injectGceSshHostKey" ];
      setupSecretsForUsers.deps = lib.mkAfter [ "injectGceSshHostKey" ];

    };
  };

  # Passwordless sudo is safe here: access is SSH-key-only over Tailscale,
  # no interactive console, and deploy-rs needs it for activation.
  security.sudo.wheelNeedsPassword = false;

  nix = {
    settings.trusted-users = lib.mkForce [ "root" ];
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
    loader.timeout = 1;
    kernelParams = [
      "console=tty1"
      "console=ttyS0,115200n8"
      "systemd.journald.forward_to_console=1"
    ];
  };

  profiles.observability = {
    enable = true;
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
      traces.enable = true;
    };
    dashboards.fleet.enable = true;
    dashboards.backup = {
      enable = true;
      definition = dash.mkDashboard {
        uid = "homeserver-backup-health";
        title = "Backup Health";
        panels = [
          (dash.timeseriesPanel {
            id = 1;
            title = "Backup Age (hours)";
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 0;
              w = 12;
              h = 8;
            };
            targets = [
              (dash.target {
                expr = "(time() - restic_last_backup_timestamp_seconds) / 3600";
                legendFormat = "hours since last backup";
              })
            ];
          })
          (dash.timeseriesPanel {
            id = 2;
            title = "Check Age (hours)";
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 12;
              y = 0;
              w = 12;
              h = 8;
            };
            targets = [
              (dash.target {
                expr = "(time() - restic_last_check_timestamp_seconds) / 3600";
                legendFormat = "hours since last check";
              })
            ];
          })
        ];
      };
    };
  };

  services = {
    grafana.settings.server = {
      domain = lib.mkForce tailnetFQDN;
      root_url = "https://%(domain)s/grafana/";
      serve_from_sub_path = true;
    };

    restic.backups.b2 = {
      paths = [
        "/var/lib/vaultwarden"
        "/var/lib/grafana"
        "/var/lib/AdGuardHome"
      ];
      repository = "b2:filipnowakowicz-gcp:";
      passwordFile = config.sops.secrets.restic_password.path;
      environmentFile = config.sops.secrets.b2_credentials.path;
    };

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
      tailscale-cert = {
        extraConfig = {
          ProtectHome = false;
          ReadWritePaths = [
            "/var/lib/tailscale"
            "/var/lib/nginx/certs"
          ];
          RestrictAddressFamilies = [ "AF_UNIX" ];
        };
      };

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
        DOMAIN = "https://${tailnetFQDN}";
      };
    };

  };

  profiles.homeserverGcpNginx = {
    enable = true;
    fqdn = tailnetFQDN;
    ingestHtpasswdFile = config.sops.secrets.observability_ingest_htpasswd.path;
  };

  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    secrets = {
      user_password.neededForUsers = true;
      tailscale_auth_key = { };
      grafana_admin_password = {
        owner = "grafana";
      };
      grafana_secret_key = {
        owner = "grafana";
      };
      observability_ingest_htpasswd = {
        owner = config.services.nginx.user;
        inherit (config.services.nginx) group;
      };
      restic_password = { };
      b2_credentials = { };
    };
  };

  users.users = {
    user = {
      home = "/home/user";
      hashedPasswordFile = config.sops.secrets.user_password.path;
    };
  };

}
