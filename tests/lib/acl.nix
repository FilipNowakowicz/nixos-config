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
    mac = {
      role = "desktop";
      tailscale = {
        tag = "workstation";
        acceptFrom.workstation = [
          22
          22
        ];
      };
    };
    homeserver-gcp = {
      role = "homeserver";
      tailnetFQDN = "homeserver-gcp.example.ts.net";
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
    internal-vm = {
      role = "internal-vm";
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

    # One grouped workstation rule, plus admin break-glass.
    testAclCount = {
      expr = lib.length result.acls;
      expected = 2;
    };

    testFirstAclSrc = {
      expr = (lib.elemAt result.acls 0).src;
      expected = [ "tag:workstation" ];
    };

    testFirstAclDst = {
      expr = (lib.elemAt result.acls 0).dst;
      expected = [
        "tag:server:22"
        "tag:server:443"
        "tag:workstation:22"
      ];
    };

    testSecondAclSrc = {
      expr = (lib.elemAt result.acls 1).src;
      expected = [ "autogroup:admin" ];
    };

    testSecondAclDst = {
      expr = (lib.elemAt result.acls 1).dst;
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

    testNoWildcardServerDestination = {
      expr = lib.any (rule: lib.any (dst: dst == "tag:server:*") rule.dst) result.acls;
      expected = false;
    };

    testNoImplicitReverseWildcardWorkstationDestination = {
      expr = lib.any (rule: lib.any (dst: dst == "tag:workstation:*") rule.dst) result.acls;
      expected = false;
    };

    testNoServerSourceRule = {
      expr = lib.any (rule: rule.src == [ "tag:server" ]) result.acls;
      expected = false;
    };

    testHasServerDestinationPorts = {
      expr = lib.any (
        rule:
        rule.src == [ "tag:workstation" ]
        && builtins.elem "tag:server:22" rule.dst
        && builtins.elem "tag:server:443" rule.dst
      ) result.acls;
      expected = true;
    };

    testHasWorkstationPeerRule = {
      expr = lib.any (
        rule: rule.src == [ "tag:workstation" ] && builtins.elem "tag:workstation:22" rule.dst
      ) result.acls;
      expected = true;
    };

    # Deduplication: duplicate ports in acceptFrom must not produce duplicate rules.
    testBackupMetadataDoesNotChangeAclCount = {
      expr = lib.length result.acls;
      expected = 2;
    };

    testNonTailscaleHostExcludedFromTagOwners = {
      expr = result.tagOwners ? "tag:internal-vm";
      expected = false;
    };
  };
in
if failures == [ ] then
  pkgs.runCommand "lib-acl-tests" { } "touch $out"
else
  throw "lib/acl.nix tests failed:\n${lib.generators.toPretty { } failures}"
