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
  expectedTrustedUsers = [
    "root"
    "user"
  ];
  actualTrustedUsers = config.nix.settings.trusted-users or [ ];
  missingTrustedUsers = lib.filter (
    user: !(builtins.elem user actualTrustedUsers)
  ) expectedTrustedUsers;
  unexpectedTrustedUsers = lib.filter (
    user: !(builtins.elem user expectedTrustedUsers)
  ) actualTrustedUsers;
  trustedUserViolations = lib.filter (msg: msg != "") [
    (lib.optionalString (
      missingTrustedUsers != [ ]
    ) "missing trusted users: ${lib.concatStringsSep ", " missingTrustedUsers}")
    (lib.optionalString (
      unexpectedTrustedUsers != [ ]
    ) "unexpected trusted users: ${lib.concatStringsSep ", " unexpectedTrustedUsers}")
  ];
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

  assertions = [
    {
      assertion = trustedUserViolations == [ ];
      message = "homeserver-gcp nix.settings.trusted-users must stay minimal: ${lib.concatStringsSep "; " trustedUserViolations}";
    }
  ];

  nix = {
    # deploy-rs remoteBuild connects as `user`; trust it so remote builds do not
    # trip restricted-setting warnings from the daemon.
    settings.trusted-users = lib.mkForce [
      "root"
      "user"
    ];
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

  environment.enableAllTerminfo = true;

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
        DOMAIN = "https://${tailnetFQDN}";
      };
    };
  };

  profiles.homeserverGcpNginx = {
    enable = true;
    fqdn = tailnetFQDN;
    ingestHtpasswdFile = config.sops.secrets.observability_ingest_htpasswd.path;
    grafanaAuthRequestUrl = "http://127.0.0.1:3180/auth";
  };

  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    secrets = {
      user_password.neededForUsers = true;
      tailscale_auth_key = { };
      grafana_admin_password.owner = "grafana";
      grafana_secret_key.owner = "grafana";
      observability_ingest_htpasswd = {
        owner = config.services.nginx.user;
        inherit (config.services.nginx) group;
      };
      restic_password = { };
      b2_credentials = { };
    };
  };

  users.users.user = {
    home = "/home/user";
    hashedPasswordFile = config.sops.secrets.user_password.path;
  };
}
