{
  deploy-rs,
  lib,
  hostRegistry,
  allNixosConfigs,
  deployCheckNixosConfigs,
}:
let
  deployableHosts = lib.filterAttrs (_: cfg: cfg ? deploy) hostRegistry;

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
      confirmTimeout = 30;
      profiles.system = {
        user = "root";
        path = deploy-rs.lib.${cfg.system}.activate.nixos nixosConfigs.${name};
      };
    }) deployableHosts;

  allDeployNodes = mkDeployNodes allNixosConfigs;

  ciDeployNodes = mkDeployNodes deployCheckNixosConfigs;
in
{
  inherit allDeployNodes ciDeployNodes;
}
