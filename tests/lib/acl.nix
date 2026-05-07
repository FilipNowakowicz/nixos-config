# Unit tests for Tailscale ACL generator.
{
  nixpkgs,
  system,
  ...
}:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};
  acl = import ../../lib/acl.nix { inherit lib; };

  testRegistry = {
    main = {
      role = "workstation";
      tailscale.tag = "workstation";
      backup.class = "standard";
    };
    homeserver = {
      role = "homeserver";
      tailnetFQDN = "homeserver.example.ts.net";
      tailscale = {
        tag = "server";
        acceptFrom.workstation = [
          443
          22
          443
        ];
      };
      backup.class = "critical";
    };
    homeserver-vm = {
      role = "homeserver-vm";
      ip = "10.0.100.2";
      # no tailscale — must be ignored by generator
    };
  };

  result = acl.mkAcl testRegistry;

  failures = lib.runTests {
    testTagOwnersWorkstation = {
      expr = result.tagOwners."tag:workstation";
      expected = [ "autogroup:admin" ];
    };

    testTagOwnersServer = {
      expr = result.tagOwners."tag:server";
      expected = [ "autogroup:admin" ];
    };

    testTagOwnerCount = {
      expr = lib.length (lib.attrNames result.tagOwners);
      expected = 2;
    };

    testNoHostsKey = {
      expr = result ? hosts;
      expected = false;
    };

    testAclOutputShapeRemainsMinimal = {
      expr = builtins.sort builtins.lessThan (builtins.attrNames result);
      expected = [
        "acls"
        "tagOwners"
      ];
    };

    # Two tag-pair rules (server↔workstation) plus the admin break-glass.
    testAclCount = {
      expr = lib.length result.acls;
      expected = 3;
    };

    # Rules are sorted by "srcTag→dstTag"; server < workstation alphabetically.
    testFirstAclSrc = {
      expr = (lib.elemAt result.acls 0).src;
      expected = [ "tag:server" ];
    };

    testFirstAclDst = {
      expr = (lib.elemAt result.acls 0).dst;
      expected = [ "tag:workstation:*" ];
    };

    testSecondAclSrc = {
      expr = (lib.elemAt result.acls 1).src;
      expected = [ "tag:workstation" ];
    };

    testSecondAclDst = {
      expr = (lib.elemAt result.acls 1).dst;
      expected = [ "tag:server:*" ];
    };

    testThirdAclSrc = {
      expr = (lib.elemAt result.acls 2).src;
      expected = [ "autogroup:admin" ];
    };

    testThirdAclDst = {
      expr = (lib.elemAt result.acls 2).dst;
      expected = [ "*:*" ];
    };

    testAllAclsAccept = {
      expr = lib.all (rule: rule.action == "accept") result.acls;
      expected = true;
    };

    # Tag-based rules cover all servers/workstations; no host-specific FQDN entries.
    testNoFqdnInRules = {
      expr = lib.any (rule: lib.any (dst: lib.hasInfix "example.ts.net" dst) rule.dst) result.acls;
      expected = false;
    };

    # Wildcard server destination is expected (tag:server:*).
    testHasWildcardServerDestination = {
      expr = lib.any (rule: lib.any (dst: dst == "tag:server:*") rule.dst) result.acls;
      expected = true;
    };

    # Bidirectional: servers must also be able to respond to workstations.
    testHasWildcardWorkstationDestination = {
      expr = lib.any (rule: lib.any (dst: dst == "tag:workstation:*") rule.dst) result.acls;
      expected = true;
    };

    # Deduplication: duplicate ports in acceptFrom must not produce duplicate rules.
    testBackupMetadataDoesNotChangeAclCount = {
      expr = lib.length result.acls;
      expected = 3;
    };

    testNonTailscaleHostExcludedFromTagOwners = {
      expr = result.tagOwners ? "tag:homeserver-vm";
      expected = false;
    };
  };
in
if failures == [ ] then
  pkgs.runCommand "lib-acl-tests" { } "touch $out"
else
  throw "lib/acl.nix tests failed:\n${lib.generators.toPretty { } failures}"
