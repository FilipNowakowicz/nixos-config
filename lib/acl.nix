# Tailscale ACL generator — derives tag owners and bidirectional access rules
# from acceptFrom relationships in the host registry.
# Feed the output to builtins.toJSON for acl.hujson.
# Rules are tag-to-tag (not per-FQDN) so new nodes join the correct group
# automatically and return traffic is always permitted.
{ lib }:
let
  tailscaleHosts = hosts: lib.filterAttrs (_: cfg: cfg ? tailscale) hosts;

  collectTagNames =
    hosts: lib.unique (map (cfg: cfg.tailscale.tag) (lib.attrValues (tailscaleHosts hosts)));

  sortedUnique = values: builtins.sort builtins.lessThan (lib.unique values);

  mkTagOwners =
    tags:
    lib.listToAttrs (
      map (tag: {
        name = "tag:${tag}";
        value = [ "autogroup:admin" ];
      }) tags
    );

  # Collect unique (srcTag, dstTag) pairs from all acceptFrom relationships.
  # acceptFrom.X on a host with tag Y means tag:X → tag:Y is needed.
  collectTagPairs =
    hostRegistry:
    let
      hosts = lib.attrValues (tailscaleHosts hostRegistry);
      pairs = builtins.concatMap (
        cfg:
        let
          acceptFrom = cfg.tailscale.acceptFrom or { };
          dstTag = cfg.tailscale.tag;
        in
        map (srcTag: "${srcTag}→${dstTag}") (builtins.attrNames acceptFrom)
      ) hosts;
      uniqueKeys = sortedUnique pairs;
    in
    map (
      key:
      let
        parts = lib.splitString "→" key;
      in
      {
        srcTag = builtins.elemAt parts 0;
        dstTag = builtins.elemAt parts 1;
      }
    ) uniqueKeys;

  # For each unique (srcTag, dstTag) pair, emit both directions so TCP return
  # traffic passes the stateless packet filter on each node.
  mkTagAclRules =
    hostRegistry:
    let
      fwdPairs = collectTagPairs hostRegistry;
      # Reverse direction for return traffic.
      revKeys = sortedUnique (map (p: "${p.dstTag}→${p.srcTag}") fwdPairs);
      revPairs = map (
        key:
        let
          parts = lib.splitString "→" key;
        in
        {
          srcTag = builtins.elemAt parts 0;
          dstTag = builtins.elemAt parts 1;
        }
      ) revKeys;
      allKeys = sortedUnique (
        (map (p: "${p.srcTag}→${p.dstTag}") fwdPairs) ++ (map (p: "${p.srcTag}→${p.dstTag}") revPairs)
      );
      allPairs = map (
        key:
        let
          parts = lib.splitString "→" key;
        in
        {
          srcTag = builtins.elemAt parts 0;
          dstTag = builtins.elemAt parts 1;
        }
      ) allKeys;
    in
    map (p: {
      action = "accept";
      src = [ "tag:${p.srcTag}" ];
      dst = [ "tag:${p.dstTag}:*" ];
    }) allPairs;

in
{
  # Generate a Tailscale ACL attrset from the host registry.
  # Hosts without a `tailscale` attribute are ignored.
  # Tag-to-tag bidirectional rules are derived from acceptFrom relationships.
  # Serialize with builtins.toJSON to get acl.hujson content.
  mkAcl = hostRegistry: {
    tagOwners = mkTagOwners (collectTagNames hostRegistry);
    acls = (mkTagAclRules hostRegistry) ++ [
      {
        # Deliberate break-glass access for tailnet admins.
        action = "accept";
        src = [ "autogroup:admin" ];
        dst = [ "*:*" ];
      }
    ];
  };
}
