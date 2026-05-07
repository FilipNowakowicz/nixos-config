{
  nixpkgs,
  system,
  ...
}:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};
  invariants = import ../../lib/invariants.nix { inherit lib pkgs; };

  sampleResults = invariants.evaluateAssertions [
    {
      name = "bool checks remain supported";
      check = _: true;
    }
    {
      name = "rich message is preserved";
      check = _: {
        passed = false;
        message = "detailed failure";
      };
    }
    {
      name = "missing message falls back to name";
      check = _: { passed = false; };
    }
  ] { };

  baseConfig = {
    nix.settings.trusted-users = [ "root" ];
    networking.hostName = "homeserver-gcp";
    networking.firewall = {
      allowedTCPPorts = [ ];
      interfaces.tailscale0.allowedTCPPorts = [
        22
        443
      ];
    };
    services = {
      openssh.enable = true;
      tailscale.enable = true;
      restic.backups.local.repository = "/persist/restic-repo";
    };
    systemd.network.networks."20-eth".networkConfig.Address = "10.0.100.2/24";
  };

  hostMeta = {
    deploy.sshUser = "user";
    backup.class = "critical";
    tailscale.tag = "server";
    ip = "10.0.100.2";
  };

  assertions = invariants.mkRegistryAssertions "homeserver-gcp" hostMeta;

  runAssertion =
    name: cfg:
    let
      assertion = lib.findFirst (candidate: candidate.name == name) null assertions;
    in
    if assertion == null then throw "missing assertion '${name}'" else assertion.check cfg;

  failures = lib.runTests {
    testBoolCheckPasses = {
      expr = (lib.elemAt sampleResults 0).passed;
      expected = true;
    };

    testBoolCheckDefaultsMessageToName = {
      expr = (lib.elemAt sampleResults 0).message;
      expected = "bool checks remain supported";
    };

    testRichMessageIsPreserved = {
      expr = (lib.elemAt sampleResults 1).message;
      expected = "detailed failure";
    };

    testMissingMessageFallsBackToName = {
      expr = (lib.elemAt sampleResults 2).message;
      expected = "missing message falls back to name";
    };

    testInvalidResultIsRejected = {
      expr = (builtins.tryEval (invariants.normalizeCheckResult "broken" { nope = true; })).success;
      expected = false;
    };

    hostnameMatchesRegistryKey = {
      expr = runAssertion "networking.hostName matches registry key" baseConfig;
      expected = true;
    };

    deployableHostsRequireOpenSsh = {
      expr = runAssertion "deployable hosts enable OpenSSH" (
        baseConfig
        // {
          services = baseConfig.services // {
            openssh.enable = false;
          };
        }
      );
      expected = false;
    };

    backupMetadataRequiresRestic = {
      expr = runAssertion "backup metadata configures local Restic backup" (
        baseConfig
        // {
          services = baseConfig.services // {
            restic.backups = { };
          };
        }
      );
      expected = false;
    };

    tailnetMetadataRequiresTailscale = {
      expr = runAssertion "tailnet metadata enables Tailscale" (
        baseConfig
        // {
          services = baseConfig.services // {
            tailscale.enable = false;
          };
        }
      );
      expected = false;
    };

    staticIpMatchesConfiguredAddress = {
      expr = runAssertion "static IP metadata matches configured address" baseConfig;
      expected = true;
    };

    staticIpMismatchFails = {
      expr = runAssertion "static IP metadata matches configured address" (
        baseConfig
        // {
          systemd.network.networks."20-eth".networkConfig.Address = "10.0.100.3/24";
        }
      );
      expected = false;
    };

    trustedUsersMatchExpectedSet = {
      expr = (invariants.checkExpectedTrustedUsers [ "root" ] baseConfig).passed;
      expected = true;
    };

    trustedUsersRejectUnexpectedUsers = {
      expr =
        (invariants.checkExpectedTrustedUsers [ "root" ] (
          baseConfig
          // {
            nix.settings.trusted-users = [
              "root"
              "user"
            ];
          }
        )).message;
      expected = "unexpected trusted users: user";
    };

    trustedUsersRejectMissingExpectedUsers = {
      expr =
        (invariants.checkExpectedTrustedUsers [
          "root"
          "builder"
        ] baseConfig).message;
      expected = "missing trusted users: builder";
    };

    noGlobalTcpPortsPasses = {
      expr = (invariants.checkNoGlobalTCPPorts [ 22 443 ] baseConfig).passed;
      expected = true;
    };

    noGlobalTcpPortsRejectsExposure = {
      expr =
        (invariants.checkNoGlobalTCPPorts [ 22 443 ] (
          baseConfig
          // {
            networking.firewall = baseConfig.networking.firewall // {
              allowedTCPPorts = [ 443 ];
            };
          }
        )).message;
      expected = "ports must not be globally open: 443";
    };

    tcpPortsRestrictedToInterfacePasses = {
      expr =
        (invariants.checkTCPPortsRestrictedToInterface {
          interface = "tailscale0";
          ports = [
            22
            443
          ];
        } baseConfig).passed;
      expected = true;
    };

    tcpPortsRestrictedToInterfaceRejectsMissingTargetPort = {
      expr =
        (invariants.checkTCPPortsRestrictedToInterface
          {
            interface = "tailscale0";
            ports = [
              22
              443
            ];
          }
          (
            baseConfig
            // {
              networking.firewall = baseConfig.networking.firewall // {
                interfaces.tailscale0.allowedTCPPorts = [ 22 ];
              };
            }
          )
        ).message;
      expected = "networking.firewall.interfaces.tailscale0.allowedTCPPorts must include: 443";
    };

    tcpPortsRestrictedToInterfaceRejectsOtherInterfaces = {
      expr =
        (invariants.checkTCPPortsRestrictedToInterface
          {
            interface = "tailscale0";
            ports = [
              22
              443
            ];
          }
          (
            baseConfig
            // {
              networking.firewall = baseConfig.networking.firewall // {
                interfaces = baseConfig.networking.firewall.interfaces // {
                  eth0.allowedTCPPorts = [ 22 ];
                };
              };
            }
          )
        ).message;
      expected = "ports must not be exposed on non-tailscale0 interfaces: eth0 (22)";
    };
  };
in
if failures == [ ] then
  pkgs.runCommand "lib-invariants-tests" { } "touch $out"
else
  throw "lib/invariants.nix tests failed:\n${lib.generators.toPretty { } failures}"
