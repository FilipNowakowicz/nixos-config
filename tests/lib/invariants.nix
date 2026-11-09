{
  nixpkgs,
  system,
  ...
}:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};
  invariants = import ../../lib/invariants.nix { inherit lib pkgs; };

  # The real host registry, so the AdGuard DNS-grant invariant is validated
  # against live data in merge-gate: a newly-added tagged host that forgets its
  # :53 grant fails this test, not a silent DNS outage on the new host.
  realHostRegistry = import ../../lib/hosts.nix;

  # Synthetic registry for the AdGuard DNS-grant invariant: homeserver-gcp
  # (tag:server, exempt) admits workstation and builder on :53; the inactive
  # `legacy` host is excluded by the status filter.
  dnsGrantRegistry = {
    main = {
      status = "active";
      tailscale.tag = "workstation";
    };
    homeserver-gcp = {
      status = "active";
      tailscale = {
        tag = "server";
        acceptFrom = {
          workstation = [
            22
            53
          ];
          builder = [ 53 ];
        };
      };
    };
    gcp-builder = {
      status = "active";
      tailscale.tag = "builder";
    };
    old = {
      status = "inactive";
      tailscale.tag = "legacy";
    };
  };

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
      - path_regex: ^hosts/main/secrets/.*
        key_groups:
          - age:
              - *user
              - *main_host
      - path_regex: ^hosts/homeserver-gcp/secrets/.*
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

  setenvAllCommand = {
    command = "ALL";
    options = [ "SETENV" ];
  };

  nopasswd = command: {
    inherit command;
    options = [ "NOPASSWD" ];
  };

  mainSudoRootSetenvRule = {
    users = [ "root" ];
    commands = [ setenvAllCommand ];
  };

  mainSudoWheelSetenvRule = {
    groups = [ "wheel" ];
    commands = [ setenvAllCommand ];
  };

  mainSudoAgentMaintenanceRule = {
    users = [ "user" ];
    commands = map nopasswd invariants.mainExpectedAgentMaintenanceCommands;
  };

  mainSudoBtrbkRule = {
    users = [ "btrbk" ];
    commands = map nopasswd [
      "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-btrfs-progs-1.0/bin/btrfs"
      "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-coreutils-9.0/bin/mkdir"
      "/nix/store/cccccccccccccccccccccccccccccccc-coreutils-9.0/bin/readlink"
      "/run/current-system/sw/bin/btrfs"
      "/run/current-system/sw/bin/mkdir"
      "/run/current-system/sw/bin/readlink"
    ];
  };

  mainSudoExtraRulesGood = [
    mainSudoRootSetenvRule
    mainSudoWheelSetenvRule
    mainSudoAgentMaintenanceRule
    mainSudoBtrbkRule
  ];

  checkMainSudoExtraRules =
    extraRules:
    invariants.mainAgentMaintenanceSudoAllowlist.check { security.sudo.extraRules = extraRules; };

  assertions = invariants.mkRegistryAssertions "homeserver-gcp" hostMeta;

  hostMetaWithAcceptFrom = hostMeta // {
    tailscale = hostMeta.tailscale // {
      acceptFrom.workstation = [
        22
        443
      ];
    };
  };

  assertionsWithAcceptFrom = invariants.mkRegistryAssertions "homeserver-gcp" hostMetaWithAcceptFrom;

  runAssertionFrom =
    assertionList: name: cfg:
    let
      assertion = lib.findFirst (candidate: candidate.name == name) null assertionList;
    in
    if assertion == null then throw "missing assertion '${name}'" else assertion.check cfg;

  runAssertion =
    name: cfg:
    let
      assertion = lib.findFirst (candidate: candidate.name == name) null assertions;
    in
    if assertion == null then throw "missing assertion '${name}'" else assertion.check cfg;

  bluetoothBootConfig = {
    hardware.bluetooth.enable = true;
    boot.blacklistedKernelModules = [ "btusb" ];
    systemd.services.bluetooth-load-btusb.enable = true;
    systemd.timers.bluetooth-load-btusb = {
      enable = true;
      wantedBy = [ "timers.target" ];
      timerConfig.OnActiveSec = "10s";
    };
  };
  checkBluetoothTimer =
    timer:
    invariants.mainBluetoothDriverHasBootTrigger.check (
      lib.recursiveUpdate bluetoothBootConfig { systemd.timers.bluetooth-load-btusb = timer; }
    );

  failures = lib.runTests {
    testMinimalObservabilityPasses = {
      expr = (invariants.observabilityStaysMinimal.check { }).passed;
      expected = true;
    };
    testMinimalObservabilityRejectsEachRemovedService = {
      expr =
        map
          (
            name:
            (invariants.observabilityStaysMinimal.check {
              services.${name}.enable = true;
            }).passed
          )
          [
            "mimir"
            "tempo"
            "opentelemetry-collector"
          ];
      expected = [
        false
        false
        false
      ];
    };

    testBluetoothDriverHasIndependentBootTrigger = {
      expr = (invariants.mainBluetoothDriverHasBootTrigger.check bluetoothBootConfig).passed;
      expected = true;
    };

    testBluetoothDriverRejectsOriginalServiceOnlyTrigger = {
      expr =
        (invariants.mainBluetoothDriverHasBootTrigger.check (
          bluetoothBootConfig
          // {
            systemd = {
              services.bluetooth-load-btusb = {
                enable = true;
                requiredBy = [ "bluetooth.service" ];
              };
              timers = { };
            };
          }
        )).passed;
      expected = false;
    };

    testBluetoothDriverRejectsDisabledTimer = {
      expr = (checkBluetoothTimer { enable = false; }).passed;
      expected = false;
    };

    testBluetoothDriverRejectsMissingBootTarget = {
      expr = (checkBluetoothTimer { wantedBy = [ "bluetooth.target" ]; }).passed;
      expected = false;
    };

    testBluetoothDriverRejectsMissingActivation = {
      expr = (checkBluetoothTimer { timerConfig.OnActiveSec = null; }).passed;
      expected = false;
    };

    testBluetoothDriverRejectsWrongTimerService = {
      expr = (checkBluetoothTimer { timerConfig.Unit = "unrelated.service"; }).passed;
      expected = false;
    };

    testBluetoothDriverRejectsDisabledLoader = {
      expr =
        (invariants.mainBluetoothDriverHasBootTrigger.check (
          lib.recursiveUpdate bluetoothBootConfig { systemd.services.bluetooth-load-btusb.enable = false; }
        )).passed;
      expected = false;
    };

    testBluetoothDriverAllowsDeliberatelyDisabledBluetooth = {
      expr =
        (invariants.mainBluetoothDriverHasBootTrigger.check {
          hardware.bluetooth.enable = false;
        }).passed;
      expected = true;
    };

    testBluetoothDriverAllowsNormalUdevLoading = {
      expr =
        (invariants.mainBluetoothDriverHasBootTrigger.check {
          hardware.bluetooth.enable = true;
          boot.blacklistedKernelModules = [ ];
        }).passed;
      expected = true;
    };

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

    testHostnameMatchesRegistryKey = {
      expr = runAssertion "networking.hostName matches registry key" baseConfig;
      expected = true;
    };

    testDeployableHostsRequireOpenSsh = {
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

    testBackupMetadataRequiresRestic = {
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

    testBackupMetadataAcceptsRepositoryFile = {
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

    testBackupMetadataRequiresPaths = {
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

    testTailnetMetadataRequiresTailscale = {
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

    testTailscale0PortsAssertionAbsentWithoutAcceptFrom = {
      expr = lib.any (a: a.name == "tailscale0 firewall ports match registry acceptFrom") assertions;
      expected = false;
    };

    testTailscale0PortsAssertionPresentWithAcceptFrom = {
      expr = lib.any (
        a: a.name == "tailscale0 firewall ports match registry acceptFrom"
      ) assertionsWithAcceptFrom;
      expected = true;
    };

    testTailscale0PortsMatchAcceptFromPasses = {
      expr =
        (runAssertionFrom assertionsWithAcceptFrom "tailscale0 firewall ports match registry acceptFrom"
          baseConfig
        ).passed;
      expected = true;
    };

    testTailscale0PortsMatchAcceptFromRejectsMismatch = {
      expr =
        (runAssertionFrom assertionsWithAcceptFrom "tailscale0 firewall ports match registry acceptFrom" (
          baseConfig
          // {
            networking.firewall = baseConfig.networking.firewall // {
              interfaces.tailscale0 = {
                allowedTCPPorts = [ 22 ];
                allowedUDPPorts = [ 21027 ];
              };
            };
          }
        )).message;
      expected = "tailscale.acceptFrom admits port(s) not opened on tailscale0: 443; tailscale0 opens port(s) not admitted by tailscale.acceptFrom: 21027";
    };

    testSopsRecipientParityPasses = {
      expr = (invariants.checkSopsRecipientParity hostRegistry matchingSopsYaml).passed;
      expected = true;
    };

    testSopsRecipientParityRejectsMissingAndStaleHosts = {
      expr =
        (invariants.checkSopsRecipientParity hostRegistry ''
          keys:
            - &main_host age1main
            - &old_host age1old
          creation_rules:
            - path_regex: ^hosts/main/secrets/.*
              key_groups:
                - age:
                    - *main_host
            - path_regex: ^hosts/old/secrets/.*
        '').message;
      expected = ".sops.yaml missing host secret rule(s): homeserver-gcp; .sops.yaml has stale host secret rule(s): old; .sops.yaml missing host recipient key(s): homeserver-gcp; .sops.yaml has stale host recipient key(s): old";
    };

    testSopsRecipientParityRejectsUnlistedHostKey = {
      expr =
        (invariants.checkSopsRecipientParity hostRegistry ''
          keys:
            - &main_host age1main
            - &homeserver_gcp_host age1hs
          creation_rules:
            - path_regex: ^hosts/main/secrets/.*
              key_groups:
                - age:
                    - *main_host
            - path_regex: ^hosts/homeserver-gcp/secrets/.*
              key_groups:
                - age:
                    - *user
        '').message;
      expected = ".sops.yaml defines but never lists host recipient key(s): homeserver-gcp";
    };

    testDeployTargetsHaveTailnetAddressesPasses = {
      expr = (invariants.checkDeployTargetsHaveTailnetAddresses hostRegistry).passed;
      expected = true;
    };

    testDeployTargetsHaveTailnetAddressesRejectsMissingTailnetMetadata = {
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

    # Validates the live registry: homeserver-gcp must admit every active tag
    # (workstation, builder, agent) on :53, with tag:server exempt as the
    # AdGuard host itself. Catches a newly-added tagged host that forgets DNS.
    testTailnetTagsHaveAdguardDnsGrantPassesOnRealRegistry = {
      expr = (invariants.checkTailnetTagsHaveAdguardDnsGrant realHostRegistry).passed;
      expected = true;
    };

    testTailnetTagsHaveAdguardDnsGrantPasses = {
      expr = (invariants.checkTailnetTagsHaveAdguardDnsGrant dnsGrantRegistry).passed;
      expected = true;
    };

    testTailnetTagsHaveAdguardDnsGrantRejectsUngrantedTag = {
      expr =
        (invariants.checkTailnetTagsHaveAdguardDnsGrant (
          dnsGrantRegistry
          // {
            other-host = {
              status = "active";
              tailscale.tag = "agent";
            };
          }
        )).message;
      expected = "tailnet tag(s) missing AdGuard DNS (port 53) grant in homeserver-gcp.tailscale.acceptFrom: agent";
    };

    # Auth-key autoconnect host (enable + authKeyFile) must carry --reset.
    testTailscaleAutoconnectNormalizesPrefsPassesWithReset = {
      expr =
        (invariants.tailscaleAutoconnectNormalizesPrefs.check {
          services.tailscale = {
            enable = true;
            authKeyFile = "/var/lib/tailscale-authkey";
            extraUpFlags = [
              "--advertise-tags=tag:builder"
              "--reset"
            ];
          };
        }).passed;
      expected = true;
    };

    testTailscaleAutoconnectNormalizesPrefsRejectsMissingReset = {
      expr =
        (invariants.tailscaleAutoconnectNormalizesPrefs.check {
          services.tailscale = {
            enable = true;
            authKeyFile = "/var/lib/tailscale-authkey";
            extraUpFlags = [ "--advertise-tags=tag:builder" ];
          };
        }).passed;
      expected = false;
    };

    # Interactive host (no authKeyFile) never autoconnects, so it is exempt.
    testTailscaleAutoconnectNormalizesPrefsExemptsInteractiveHost = {
      expr =
        (invariants.tailscaleAutoconnectNormalizesPrefs.check {
          services.tailscale = {
            enable = true;
            authKeyFile = null;
            extraUpFlags = [ ];
          };
        }).passed;
      expected = true;
    };

    testImpermanentHostsHaveDiskoConfigPasses = {
      expr = (invariants.checkImpermanentHostHasDiskoConfig impermanentConfig).passed;
      expected = true;
    };

    testImpermanentHostsHaveDiskoConfigRejectsMissingMountpoint = {
      expr =
        (invariants.checkImpermanentHostHasDiskoConfig (
          impermanentConfig
          // {
            disko.devices = { };
          }
        )).message;
      expected = "environment.persistence root(s) missing matching disko mountpoint: /persist";
    };

    testAnonymousSpecialisationPersistencePasses = {
      expr = (invariants.checkAnonymousSpecialisationPersistence anonymousConfig).passed;
      expected = true;
    };

    testAnonymousSpecialisationPersistenceRejectsExtraPersistedDirectory = {
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

    testMullvadTailscaleCoexistencePasses = {
      expr = (invariants.checkMullvadTailscaleCoexistence mullvadTailscaleConfig).passed;
      expected = true;
    };

    testMullvadTailscaleCoexistenceRejectsMissingMarks = {
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

    testTrustedUsersMatchExpectedSet = {
      expr = (invariants.checkExpectedTrustedUsers [ "root" ] baseConfig).passed;
      expected = true;
    };

    testTrustedUsersRejectUnexpectedUsers = {
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

    testTrustedUsersRejectMissingExpectedUsers = {
      expr =
        (invariants.checkExpectedTrustedUsers [
          "root"
          "builder"
        ] baseConfig).message;
      expected = "missing trusted users: builder";
    };

    testNoGlobalTcpPortsPasses = {
      expr = (invariants.checkNoGlobalTCPPorts [ 22 443 ] baseConfig).passed;
      expected = true;
    };

    testNoGlobalTcpPortsRejectsExposure = {
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

    testTcpPortsRestrictedToInterfacePasses = {
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

    testTcpPortsRestrictedToInterfaceRejectsMissingTargetPort = {
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

    testTcpPortsRestrictedToInterfaceRejectsOtherInterfaces = {
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

    testMainSudoAllowlistPasses = {
      expr = (checkMainSudoExtraRules mainSudoExtraRulesGood).passed;
      expected = true;
    };

    testMainSudoAllowlistRejectsUnexpectedUserRule = {
      expr =
        (checkMainSudoExtraRules (
          mainSudoExtraRulesGood
          ++ [
            {
              users = [ "evil" ];
              commands = [ (nopasswd "ALL") ];
            }
          ]
        )).passed;
      expected = false;
    };

    testMainSudoAllowlistRejectsBroadAllAdditionToAgentRule = {
      expr =
        (checkMainSudoExtraRules [
          mainSudoRootSetenvRule
          mainSudoWheelSetenvRule
          (
            mainSudoAgentMaintenanceRule
            // {
              commands = mainSudoAgentMaintenanceRule.commands ++ [ (nopasswd "ALL") ];
            }
          )
          mainSudoBtrbkRule
        ]).message;
      expected = "expected exactly 1 agent maintenance allowlist rule, got 0; main sudo extraRules contains 1 unexpected rule(s)";
    };

    testMainSudoAllowlistRejectsNonUserNopasswdResidue = {
      expr =
        (checkMainSudoExtraRules (
          mainSudoExtraRulesGood ++ [ (mainSudoAgentMaintenanceRule // { users = [ "user2" ]; }) ]
        )).passed;
      expected = false;
    };

    testMainSudoAllowlistRejectsMalformedBtrbkResidue = {
      expr =
        (checkMainSudoExtraRules [
          mainSudoRootSetenvRule
          mainSudoWheelSetenvRule
          mainSudoAgentMaintenanceRule
          (
            mainSudoBtrbkRule
            // {
              commands = (lib.take 5 mainSudoBtrbkRule.commands) ++ [ (nopasswd "/tmp/evil/bin/btrfs") ];
            }
          )
        ]).message;
      expected = "expected exactly 1 btrbk maintenance allowlist rule, got 0; main sudo extraRules contains 1 unexpected rule(s)";
    };

    testMainSudoAllowlistRejectsMissingDefaultRule = {
      expr =
        (checkMainSudoExtraRules [
          mainSudoRootSetenvRule
          mainSudoAgentMaintenanceRule
          mainSudoBtrbkRule
        ]).message;
      expected = "expected exactly 1 default wheel SETENV rule, got 0";
    };

    testMainSudoAllowlistRejectsDuplicateAgentRule = {
      expr =
        (checkMainSudoExtraRules (mainSudoExtraRulesGood ++ [ mainSudoAgentMaintenanceRule ])).message;
      expected = "expected exactly 1 agent maintenance allowlist rule, got 2";
    };

    testHomeserverDeployRunnerConfigPasses = {
      expr =
        (invariants.homeserverDeployRunnerRegistrationGcRunbookMatchesConfig.check {
          systemd.services.github-runner-homeserver-deploy = {
            serviceConfig.StateDirectory = "github-runner/homeserver-deploy";
            restartIfChanged = false;
          };
        }).passed;
      expected = true;
    };

    testHomeserverDeployRunnerConfigRejectsRestartIfChanged = {
      expr =
        (invariants.homeserverDeployRunnerRegistrationGcRunbookMatchesConfig.check {
          systemd.services.github-runner-homeserver-deploy = {
            serviceConfig.StateDirectory = "github-runner/homeserver-deploy";
            restartIfChanged = true;
          };
        }).message;
      expected = "systemd.services.github-runner-homeserver-deploy.restartIfChanged must be false (the self-deploy runner is SIGKILLed mid switch-to-configuration otherwise, half-applying activation with exit 130)";
    };

    testHomeserverDeployRunnerConfigRejectsDefaultRestartIfChanged = {
      expr =
        (invariants.homeserverDeployRunnerRegistrationGcRunbookMatchesConfig.check {
          systemd.services.github-runner-homeserver-deploy.serviceConfig.StateDirectory =
            "github-runner/homeserver-deploy";
        }).message;
      expected = "systemd.services.github-runner-homeserver-deploy.restartIfChanged must be false (the self-deploy runner is SIGKILLed mid switch-to-configuration otherwise, half-applying activation with exit 130)";
    };
  };
in
if failures == [ ] then
  pkgs.runCommand "lib-invariants-tests" { } "touch $out"
else
  throw "lib/invariants.nix tests failed:\n${lib.generators.toPretty { } failures}"
