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
    metrics = {
      role = "service";
      tailscale = {
        tag = "metrics";
        acceptFrom = {
          admin = [
            "9090"
            9091
          ];
          workstation = [
            "8443"
            8080
          ];
        };
      };
    };
    # Carries tag:admin so the metrics host's acceptFrom.admin references a
    # defined tag. Without an owner, mkAcl would (correctly) refuse to emit a
    # rule whose src is an undefined tag.
    controller = {
      role = "admin-jumpbox";
      tailscale.tag = "admin";
    };
    internal-vm = {
      role = "internal-vm";
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
      expected = 4;
    };

    testTagOwnersAdmin = {
      expr = result.tagOwners."tag:admin";
      expected = [ "autogroup:admin" ];
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

    # Grouped source rules, plus admin break-glass.
    testAclCount = {
      expr = lib.length result.acls;
      expected = 3;
    };

    testFirstAclSrc = {
      expr = (lib.elemAt result.acls 0).src;
      expected = [ "tag:admin" ];
    };

    testFirstAclDst = {
      expr = (lib.elemAt result.acls 0).dst;
      expected = [
        "tag:metrics:9090"
        "tag:metrics:9091"
      ];
    };

    testSecondAclSrc = {
      expr = (lib.elemAt result.acls 1).src;
      expected = [ "tag:workstation" ];
    };

    testSecondAclDst = {
      expr = (lib.elemAt result.acls 1).dst;
      expected = [
        "tag:metrics:8080"
        "tag:metrics:8443"
        "tag:server:22"
        "tag:server:443"
        "tag:workstation:22"
      ];
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

    testHasUnusualPortConfigDestinations = {
      expr = lib.any (
        rule:
        rule.src == [ "tag:workstation" ]
        && builtins.elem "tag:metrics:8080" rule.dst
        && builtins.elem "tag:metrics:8443" rule.dst
      ) result.acls;
      expected = true;
    };

    testAclRulesRemainSourceSortedBeforeBreakGlass = {
      expr = map (rule: rule.src) result.acls;
      expected = [
        [ "tag:admin" ]
        [ "tag:workstation" ]
        [ "autogroup:admin" ]
      ];
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
      expected = 3;
    };

    testNonTailscaleHostExcludedFromTagOwners = {
      expr = result.tagOwners ? "tag:internal-vm";
      expected = false;
    };

    testBreakGlassRulePresent = {
      expr = lib.any (
        rule: rule.action == "accept" && rule.src == [ "autogroup:admin" ] && rule.dst == [ "*:*" ]
      ) result.acls;
      expected = true;
    };

    # Invalid metadata: acceptFrom referencing a tag no host carries must throw,
    # since the emitted src would reference an undefined Tailscale tag.
    testUndefinedSourceTagThrows = {
      expr =
        (builtins.tryEval (
          builtins.deepSeq (acl.mkAcl {
            box = {
              tailscale = {
                tag = "server";
                acceptFrom.ghost = [ 22 ];
              };
            };
          }) "ok"
        )).success;
      expected = false;
    };

    # A source tag carried by another host is accepted.
    testDefinedSourceTagAcrossHostsSucceeds = {
      expr =
        (builtins.tryEval (
          builtins.deepSeq (acl.mkAcl {
            jump = {
              tailscale.tag = "admin";
            };
            server = {
              tailscale = {
                tag = "server";
                acceptFrom.admin = [ 22 ];
              };
            };
          }) "ok"
        )).success;
      expected = true;
    };
  };
in
if failures == [ ] then
  pkgs.runCommand "lib-acl-tests" { } "touch $out"
else
  throw "lib/acl.nix tests failed:\n${lib.generators.toPretty { } failures}"
