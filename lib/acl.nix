# Tailscale ACL generator — derives tag owners and access rules from
# acceptFrom relationships in the host registry.
# Feed the output to builtins.toJSON for acl.hujson.
# Rules are tag-to-tag (not per-FQDN) so new nodes join the correct group
# automatically. Tailscale ACLs are connection-oriented, so accepted inbound
# flows do not need separate reverse rules for return traffic.
{ lib }:
let
  tailscaleHosts = hosts: lib.filterAttrs (_: cfg: cfg ? tailscale) hosts;

  collectTagNames =
    hosts: lib.unique (map (cfg: cfg.tailscale.tag) (lib.attrValues (tailscaleHosts hosts)));

  # All source tags referenced by acceptFrom across every tailnet host.
  collectSourceTags =
    hosts:
    lib.unique (
      builtins.concatMap (cfg: builtins.attrNames (cfg.tailscale.acceptFrom or { })) (
        lib.attrValues (tailscaleHosts hosts)
      )
    );

  # Every acceptFrom source tag must be a tag that some host actually carries.
  # Otherwise mkAcl would emit `src = [ "tag:X" ]` for a tag absent from
  # tagOwners, which Tailscale rejects as an undefined tag — and the drift check
  # would only surface it on the next live apply. Fail fast at eval instead.
  assertSourceTagsDefined =
    hostRegistry: value:
    let
      definedTags = collectTagNames hostRegistry;
      undefined = lib.filter (tag: !builtins.elem tag definedTags) (collectSourceTags hostRegistry);
    in
    if undefined == [ ] then
      value
    else
      throw "lib/acl.nix: acceptFrom references undefined tag(s) ${builtins.toJSON undefined}; every source tag must be carried by some tailnet host (defined tags: ${builtins.toJSON definedTags})";

  sortedUnique = values: builtins.sort builtins.lessThan (lib.unique values);

  mkTagOwners =
    tags:
    lib.listToAttrs (
      map (tag: {
        name = "tag:${tag}";
        value = [ "autogroup:admin" ];
      }) tags
    );

  formatDestination = p: "tag:${p.dstTag}:${toString p.port}";

  # Collect unique (srcTag, dstTag, port) triples from all acceptFrom relationships.
  # acceptFrom.X on a host with tag Y means tag:X -> tag:Y:<port> is needed.
  collectTagPortTriples =
    hostRegistry:
    let
      hosts = lib.attrValues (tailscaleHosts hostRegistry);
      triples = builtins.concatMap (
        cfg:
        let
          acceptFrom = cfg.tailscale.acceptFrom or { };
          dstTag = cfg.tailscale.tag;
        in
        builtins.concatMap (
          srcTag: map (port: "${srcTag}->${dstTag}->${toString port}") (acceptFrom.${srcTag} or [ ])
        ) (builtins.attrNames acceptFrom)
      ) hosts;
      uniqueKeys = sortedUnique triples;
    in
    map (
      key:
      let
        parts = lib.splitString "->" key;
      in
      {
        srcTag = builtins.elemAt parts 0;
        dstTag = builtins.elemAt parts 1;
        port = lib.toInt (builtins.elemAt parts 2);
      }
    ) uniqueKeys;

  # Group triples by source tag. A single ACL rule can contain several
  # destination tag:port entries, preserving the registry's port boundaries.
  mkTagAclRules =
    hostRegistry:
    let
      triples = collectTagPortTriples hostRegistry;
      srcTags = sortedUnique (map (p: p.srcTag) triples);
    in
    map (srcTag: {
      action = "accept";
      src = [ "tag:${srcTag}" ];
      dst = map formatDestination (
        builtins.sort (a: b: a.dstTag < b.dstTag || (a.dstTag == b.dstTag && a.port < b.port)) (
          lib.filter (p: p.srcTag == srcTag) triples
        )
      );
    }) srcTags;

in
{
  # Generate a Tailscale ACL attrset from the host registry.
  # Hosts without a `tailscale` attribute are ignored.
  # Tag-to-tag:port rules are derived from acceptFrom relationships.
  # Serialize with builtins.toJSON to get acl.hujson content.
  # Throws if any acceptFrom source tag is not carried by some tailnet host.
  mkAcl =
    hostRegistry:
    assertSourceTagsDefined hostRegistry {
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
