{
  deploy-rs,
  lib,
  hostRegistry,
  allNixosConfigs,
  ciNixosConfigs,
}:
let
  deployableHosts = lib.filterAttrs (_: cfg: cfg ? deploy) hostRegistry;

  # Seconds deploy-rs waits for the post-activation magic-rollback confirm
  # before reverting. `mac` is Tailscale-only and impermanent, so its
  # tailscale0 interface can come up slowly after activation; a too-short
  # window would roll back an otherwise-correct deploy. Give it extra room.
  defaultConfirmTimeout = 30;
  confirmTimeouts = {
    mac = 60;
  };

  mkDeployNodes =
    nixosConfigs:
    lib.mapAttrs (name: cfg: {
      hostname = name;
      inherit (cfg.deploy) sshUser;
      magicRollback = true;
      autoRollback = true;
      remoteBuild = true;
      confirmTimeout = confirmTimeouts.${name} or defaultConfirmTimeout;
      profiles.system = {
        user = "root";
        path = deploy-rs.lib.${cfg.system}.activate.nixos nixosConfigs.${name};
      };
    }) deployableHosts;

  allDeployNodes = mkDeployNodes allNixosConfigs;

  ciDeployNodes = mkDeployNodes ciNixosConfigs;
in
{
  inherit allDeployNodes ciDeployNodes;
}
