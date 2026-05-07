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
in
{
  imports = [
    inputs.disko.nixosModules.disko
    ./hardware-configuration.nix
    ./disko.nix
    ../../modules/nixos/profiles/base.nix
    ../../modules/nixos/profiles/machine-common.nix
    ../../modules/nixos/profiles/security.nix
    ../../modules/nixos/profiles/sops-base.nix
    ../../modules/nixos/profiles/user.nix
  ];

  environment.systemPackages = [ pkgs.kitty ];

  systemd.services = {
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
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 60;
      };
    };

    nginx = {
      after = [ "tailscale-cert.service" ];
      requires = [ "tailscale-cert.service" ];
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

  nix.settings.trusted-users = lib.mkForce [
    "root"
    "user"
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
    loader.timeout = 1;
    kernelParams = [
      "console=tty1"
      "console=ttyS0,115200n8"
      "systemd.journald.forward_to_console=1"
    ];
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
      tailscale-cert = {
        extraConfig = {
          ProtectHome = false;
          ReadWritePaths = [ "/var/lib/tailscale" ];
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

    nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;

      virtualHosts.${tailnetFQDN} = {
        forceSSL = true;
        sslCertificate = "/var/lib/tailscale/certs/homeserver-gcp.crt";
        sslCertificateKey = "/var/lib/tailscale/certs/homeserver-gcp.key";

        locations."/" = {
          proxyPass = "http://127.0.0.1:8222";
          proxyWebsockets = true;
        };
      };
    };
  };

  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    secrets = {
      user_password.neededForUsers = true;
      tailscale_auth_key = { };
    };
  };

  users.users = {
    user = {
      home = "/home/user";
      hashedPasswordFile = config.sops.secrets.user_password.path;
    };
  };

}
