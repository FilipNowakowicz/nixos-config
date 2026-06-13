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
      # Registry tailnetFQDN is the deploy addressing source of truth;
      # fall back to the bare name only for a deploy target that genuinely
      # lacks tailnet metadata (checkDeployTargetsHaveTailnetAddresses still
      # permits `tailscale` without `tailnetFQDN`).
      hostname = cfg.tailnetFQDN or name;
      # tailnetFQDN (e.g. "homeserver-gcp.tail90fc7a.ts.net") is a different
      # known_hosts key than the bare registry name used before #142, so
      # existing known_hosts entries (keyed by the short MagicDNS name) don't
      # match it. TOFU-accept the FQDN's host key on first connect — same
      # tailnet-only, key-only trust model already used for the
      # gcp-builder build link and the homeserver-gcp self-deploy
      # "Check failed units" step.
      sshOpts = [
        "-o"
        "StrictHostKeyChecking=accept-new"
      ];
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
