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
      restic.backups.local.paths = [ "/home/user" ];
    };
  };

  hostMeta = {
    deploy.sshUser = "user";
    backup.class = "critical";
    tailscale.tag = "server";
  };

  hostRegistry = {
    main = {
      status = "active";
      tailnetFQDN = "main.tail.example";
      tailscale.tag = "workstation";
    };
    homeserver-gcp = {
      status = "active";
      deploy.sshUser = "user";
      tailscale.tag = "server";
    };
    gcp-builder = {
      status = "active";
      deploy.sshUser = "user";
      tailscale.tag = "server";
      sops = false;
    };
    old = {
      status = "inactive";
      tailnetFQDN = "old.tail.example";
    };
  };

  matchingSopsYaml = ''
    keys:
      - &user age1user
      - &main_host age1main
      - &homeserver_gcp_host age1homeserver
    creation_rules:
      - path_regex: hosts/main/secrets/.*
        key_groups:
          - age:
              - *user
              - *main_host
      - path_regex: hosts/homeserver-gcp/secrets/.*
        key_groups:
          - age:
              - *user
              - *homeserver_gcp_host
  '';

  impermanentConfig = {
    environment.persistence."/persist".directories = [ "/var/lib/nixos" ];
    disko.devices.disk.main.content.subvolumes."/@persist".mountpoint = "/persist";
  };

  anonymousConfig = {
    specialisation.anonymous.configuration.environment.persistence."/persist" = {
      directories = [
        "/var/lib/nixos"
        "/var/lib/systemd/backlight"
        "/var/lib/systemd/rfkill"
      ];
      files = [
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
      ];
    };
  };

  mullvadTailscaleConfig = {
    networking = {
      firewall.checkReversePath = "loose";
      nftables.tables."tailscale-mullvad-compat".content = ''
        chain output {
          type filter hook output priority filter - 1;
          oifname "tailscale0" ct mark set 0x00000f41 meta mark set 0x6d6f6c65
        }
      '';
    };
    services = {
      mullvad-vpn.enable = true;
      tailscale.enable = true;
    };
    systemd.services = {
      tailscale-bypass-routing = {
        after = [
          "tailscaled.service"
          "mullvad-daemon.service"
        ];
        wants = [
          "tailscaled.service"
          "mullvad-daemon.service"
        ];
        wantedBy = [ "multi-user.target" ];
      };
      tailscaled.postStart = "tailscale-bypass-rules || true";
      mullvad-daemon.postStart = "tailscale-bypass-rules || true";
      mullvad-lockdown = { };
    };
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
      expr = runAssertion "backup metadata configures Restic backup target" (
        baseConfig
        // {
          services = baseConfig.services // {
            restic.backups = { };
          };
        }
      );
      expected = false;
    };

    backupMetadataAcceptsRepositoryFile = {
      expr = runAssertion "backup metadata configures Restic backup target" (
        baseConfig
        // {
          services = baseConfig.services // {
            restic.backups.local = {
              repositoryFile = "/run/secrets/restic_repository";
              paths = [ "/home/user" ];
            };
          };
        }
      );
      expected = true;
    };

    backupMetadataRequiresPaths = {
      expr = runAssertion "backup metadata configures Restic backup target" (
        baseConfig
        // {
          services = baseConfig.services // {
            restic.backups.local = {
              repository = "/persist/restic-repo";
              paths = [ ];
            };
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

    sopsRecipientParityPasses = {
      expr = (invariants.checkSopsRecipientParity hostRegistry matchingSopsYaml).passed;
      expected = true;
    };

    sopsRecipientParityRejectsMissingAndStaleHosts = {
      expr =
        (invariants.checkSopsRecipientParity hostRegistry ''
          keys:
            - &main_host age1main
            - &old_host age1old
          creation_rules:
            - path_regex: hosts/main/secrets/.*
            - path_regex: hosts/old/secrets/.*
        '').message;
      expected = ".sops.yaml missing host secret rule(s): homeserver-gcp; .sops.yaml has stale host secret rule(s): old; .sops.yaml missing host recipient key(s): homeserver-gcp; .sops.yaml has stale host recipient key(s): old";
    };

    deployTargetsHaveTailnetAddressesPasses = {
      expr = (invariants.checkDeployTargetsHaveTailnetAddresses hostRegistry).passed;
      expected = true;
    };

    deployTargetsHaveTailnetAddressesRejectsMissingTailnetMetadata = {
      expr =
        (invariants.checkDeployTargetsHaveTailnetAddresses (
          hostRegistry
          // {
            mac = {
              status = "active";
              deploy.sshUser = "user";
            };
          }
        )).message;
      expected = "deploy target(s) missing tailnetFQDN or tailscale metadata: mac";
    };

    impermanentHostsHaveDiskoConfigPasses = {
      expr = (invariants.checkImpermanentHostHasDiskoConfig impermanentConfig).passed;
      expected = true;
    };

    impermanentHostsHaveDiskoConfigRejectsMissingMountpoint = {
      expr =
        (invariants.checkImpermanentHostHasDiskoConfig (
          impermanentConfig
          // {
            disko.devices = { };
          }
        )).message;
      expected = "environment.persistence root(s) missing matching disko mountpoint: /persist";
    };

    anonymousSpecialisationPersistencePasses = {
      expr = (invariants.checkAnonymousSpecialisationPersistence anonymousConfig).passed;
      expected = true;
    };

    anonymousSpecialisationPersistenceRejectsExtraPersistedDirectory = {
      expr =
        (invariants.checkAnonymousSpecialisationPersistence (
          anonymousConfig
          // {
            specialisation.anonymous.configuration.environment.persistence."/persist" =
              anonymousConfig.specialisation.anonymous.configuration.environment.persistence."/persist"
              // {
                directories =
                  anonymousConfig.specialisation.anonymous.configuration.environment.persistence."/persist".directories
                  ++ [ "/var/lib/tailscale" ];
              };
          }
        )).message;
      expected = "anonymous specialisation persists unexpected dir(s): /var/lib/tailscale";
    };

    mullvadTailscaleCoexistencePasses = {
      expr = (invariants.checkMullvadTailscaleCoexistence mullvadTailscaleConfig).passed;
      expected = true;
    };

    mullvadTailscaleCoexistenceRejectsMissingMarks = {
      expr =
        (invariants.checkMullvadTailscaleCoexistence (
          mullvadTailscaleConfig
          // {
            networking = mullvadTailscaleConfig.networking // {
              nftables.tables."tailscale-mullvad-compat".content = ''
                chain output {
                  type filter hook output priority filter - 1;
                  oifname "tailscale0" meta mark set 0x6d6f6c65
                }
              '';
            };
          }
        )).message;
      expected = "tailscale-mullvad-compat nftables chain must set Mullvad's conntrack bypass mark";
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
