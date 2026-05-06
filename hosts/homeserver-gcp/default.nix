{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
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

      # Temporary bootstrap SSH for first-boot recovery. Remove after Tailscale works.
      installBootstrapSsh = lib.stringAfter [ "users" ] ''
        _tmppub=$(${pkgs.coreutils}/bin/mktemp -p /run)
        _fetched=0
        for _i in 1 2 3 4 5; do
          if ${pkgs.curl}/bin/curl -sf --max-time 5 \
            -H "Metadata-Flavor: Google" \
            "http://metadata.google.internal/computeMetadata/v1/instance/attributes/bootstrap-ssh-public-key" \
            > "$_tmppub" 2>/dev/null; then
            _fetched=1
            break
          fi
          sleep 2
        done
        if [ "$_fetched" = "1" ] && [ -s "$_tmppub" ]; then
          install -d -m 700 -o bootstrap -g users /home/bootstrap/.ssh
          install -m 600 -o bootstrap -g users "$_tmppub" /home/bootstrap/.ssh/authorized_keys
        fi
        rm -f "$_tmppub"
      '';
    };
  };

  security.sudo.wheelNeedsPassword = lib.mkForce true;
  security.sudo.extraRules = [
    {
      users = [ "bootstrap" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  nix.settings.trusted-users = lib.mkForce [ "root" ];

  networking = {
    hostName = "homeserver-gcp";
    firewall = {
      allowedTCPPorts = [ 22 ];
      interfaces.tailscale0.allowedTCPPorts = [ 22 ];
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
      openFirewall = true;
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

    bootstrap = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      home = "/home/bootstrap";
      createHome = true;
    };
  };

}
