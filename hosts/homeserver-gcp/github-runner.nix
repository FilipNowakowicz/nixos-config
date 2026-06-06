{
  config,
  pkgs,
  ...
}:
{
  services.github-runners.homeserver-deploy = {
    enable = true;
    name = "homeserver-gcp-deploy";
    url = "https://github.com/FilipNowakowicz/nixos-config";
    tokenFile = config.sops.secrets.github_runner_homeserver_deploy_token.path;
    replace = true;

    # The deploy workflow is manual and main-branch gated. Run it as the same
    # account deploy-rs already uses so SSH and activation follow the existing
    # homeserver deployment path.
    user = "user";
    extraEnvironment.HOME = "/home/user";

    extraLabels = [
      "nixos"
      "homeserver-gcp"
      "homeserver-deploy"
    ];

    extraPackages = with pkgs; [
      openssh
      rsync
    ];

    serviceOverrides = {
      ProtectHome = false;
    };
  };

  systemd.services.github-runner-homeserver-deploy = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };

  # The deploy workflow runs from a runner on this host and reaches the host
  # back over `ssh user@homeserver-gcp` (deploy-rs activation + failed-unit
  # check). Authorize the dedicated self-deploy key whose private half is
  # installed at /home/user/.ssh/id_ed25519 via the
  # homeserver_selfdeploy_ssh_key sops secret (see ./default.nix).
  users.users.user.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPdNtbVSsK8QUvmf23/cytypBEjPBN/KVs9SdtwFMChC homeserver-gcp-selfdeploy"
  ];
}
