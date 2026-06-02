# Unit tests for the host registry schema helper.
{
  nixpkgs,
  system,
  ...
}:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};
  registry = import ../../lib/host-registry.nix;

  validHost = {
    system = "x86_64-linux";
    status = "active";
    deploy.sshUser = "user";
    tailnetFQDN = "host.example.ts.net";
    tailscale = {
      tag = "server";
      acceptFrom.workstation = [
        22
        443
      ];
    };
    homeManager = {
      role = "server";
      enableSpotify = false;
      packs = [ ];
    };
    backup = {
      class = "critical";
      name = "b2";
    };
    hardware.diskById = "/dev/disk/by-id/test-disk";
  };

  fails = host: !(builtins.tryEval (registry.validateHost "test" host)).success;

  failures = lib.runTests {
    testValidHostPassesThrough = {
      expr = registry.validateHost "test" validHost;
      expected = validHost;
    };

    testValidateRegistryPassesThrough = {
      expr = registry.validateRegistry { test = validHost; };
      expected = {
        test = validHost;
      };
    };

    testMissingSystemFails = {
      expr = fails (builtins.removeAttrs validHost [ "system" ]);
      expected = true;
    };

    testBadStatusFails = {
      expr = fails (validHost // { status = "retired"; });
      expected = true;
    };

    testUnknownFieldFails = {
      expr = fails (validHost // { owner = "user"; });
      expected = true;
    };

    testBadTailnetFqdnFails = {
      expr = fails (validHost // { tailnetFQDN = [ "not-a-string" ]; });
      expected = true;
    };

    testBadTailscalePortFails = {
      expr = fails (
        validHost
        // {
          tailscale = validHost.tailscale // {
            acceptFrom.workstation = [ 65536 ];
          };
        }
      );
      expected = true;
    };

    testBadHomeManagerPackFails = {
      expr = fails (
        validHost
        // {
          homeManager = validHost.homeManager // {
            role = "desktop";
            packs = [ "unknown" ];
          };
        }
      );
      expected = true;
    };

    testBadBackupClassFails = {
      expr = fails (validHost // { backup.class = "archive"; });
      expected = true;
    };

    testStableInventoryFieldsExposeClosureSize = {
      expr = builtins.elem "closureSizeBytes" registry.schema.repoLocalInventoryFields;
      expected = true;
    };
  };
in
if failures == [ ] then
  pkgs.runCommand "lib-host-registry-tests" { } "touch $out"
else
  throw "lib/host-registry.nix tests failed:\n${lib.generators.toPretty { } failures}"
