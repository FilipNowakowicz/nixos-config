{
  lib,
  pkgs,
  nixpkgs,
  inputs,
  hostRegistry,
  allNixosConfigs,
  ciNixosConfigs,
  invariants,
}:
let
  inherit (invariants) mkResult require requirePaths;

  registryAssertionsFor = hostName: invariants.mkRegistryAssertions hostName hostRegistry.${hostName};

  nixpkgsRegistryPinnedToFlakeInput = {
    name = "nixpkgs registry is pinned to the flake input";
    check =
      cfg:
      let
        expected = builtins.toString inputs.nixpkgs;
        registry = cfg.nix.registry.nixpkgs or { };
        actual = builtins.toString (registry.flake or "");
        actualTarget = builtins.toString (registry.to.path or "");
        violations = lib.filter (msg: msg != "") [
          (lib.optionalString (
            actual != expected
          ) "nix.registry.nixpkgs.flake must point at the flake input (${expected}), got ${actual}")
          (lib.optionalString (
            actualTarget != expected
          ) "nix.registry.nixpkgs.to.path must resolve to the flake input (${expected}), got ${actualTarget}")
          (lib.optionalString (
            (cfg.nix.nixPath or [ ]) != [ "nixpkgs=flake:nixpkgs" ]
          ) "nix.nixPath must be [ \"nixpkgs=flake:nixpkgs\" ]")
        ];
      in
      mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
  };

  mainInteractiveShellUsesNixIndexAndComma = {
    name = "main interactive shell uses nix-index and comma";
    check =
      cfg:
      let
        violations = lib.filter (msg: msg != "") [
          (lib.optionalString cfg.programs.command-not-found.enable "programs.command-not-found.enable must be false")
          (lib.optionalString (
            !(cfg.programs.nix-index.enable or false)
          ) "programs.nix-index.enable must be true")
          (lib.optionalString (
            !(cfg.programs.nix-index-database.comma.enable or false)
          ) "programs.nix-index-database.comma.enable must be true")
        ];
      in
      mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
  };

  # Pre-sorted so the check can compare directly without sorting a constant on every eval.
  expectedAgentMaintenanceCommands = [
    "/run/current-system/sw/bin/bootctl cleanup"
    "/run/current-system/sw/bin/bootctl status --no-pager"
    "/run/current-system/sw/bin/efibootmgr -b [0-9A-F][0-9A-F][0-9A-F][0-9A-F] -B"
    "/run/current-system/sw/bin/nix-gc-14d"
    "/run/current-system/sw/bin/nixos-switch-main"
    "/run/current-system/sw/bin/systemctl start btrbk-local.service"
    "/run/current-system/sw/bin/systemctl start restic-backups-local.service"
    "/run/current-system/sw/bin/systemctl start restic-check-local.service"
    "/run/current-system/sw/bin/systemctl status btrbk-local.service --no-pager"
    "/run/current-system/sw/bin/systemctl status btrbk-local.timer --no-pager"
    "/run/current-system/sw/bin/systemctl status restic-backups-local.service --no-pager"
    "/run/current-system/sw/bin/systemctl status restic-backups-local.timer --no-pager"
    "/run/current-system/sw/bin/systemctl status restic-check-local.service --no-pager"
    "/run/current-system/sw/bin/systemctl status restic-check-local.timer --no-pager"
  ];

  mainAgentMaintenanceSudoAllowlist = {
    name = "agent maintenance sudo allowlist stays narrow";
    check =
      cfg:
      let
        extraRules = cfg.security.sudo.extraRules or [ ];

        commandOptions = command: command.options or [ ];
        commandPath = command: command.command or "";
        commandBasename = command: builtins.baseNameOf (commandPath command);
        sortedCommandPaths = rule: lib.sort builtins.lessThan (map commandPath (rule.commands or [ ]));
        hasOnlyOptions = options: command: commandOptions command == options;

        isDefaultSetenvRule =
          rule:
          let
            commands = rule.commands or [ ];
          in
          (rule.host or "ALL") == "ALL"
          && (rule.runAs or "ALL:ALL") == "ALL:ALL"
          &&
            commands == [
              {
                command = "ALL";
                options = [ "SETENV" ];
              }
            ];

        isDefaultRootSetenvRule =
          rule: isDefaultSetenvRule rule && (rule.users or [ ]) == [ "root" ] && (rule.groups or [ ]) == [ ];

        isDefaultWheelSetenvRule =
          rule: isDefaultSetenvRule rule && (rule.users or [ ]) == [ ] && (rule.groups or [ ]) == [ "wheel" ];

        expectedCommands = expectedAgentMaintenanceCommands;
        isAgentMaintenanceRule =
          rule:
          (rule.users or [ ]) == [ "user" ]
          && (rule.groups or [ ]) == [ ]
          && sortedCommandPaths rule == expectedCommands
          && lib.all (hasOnlyOptions [ "NOPASSWD" ]) (rule.commands or [ ]);

        expectedBtrbkCommands = [
          "btrfs"
          "btrfs"
          "mkdir"
          "mkdir"
          "readlink"
          "readlink"
        ];
        isBtrbkMaintenanceRule =
          rule:
          (rule.users or [ ]) == [ "btrbk" ]
          && (rule.groups or [ ]) == [ ]
          && lib.sort builtins.lessThan (map commandBasename (rule.commands or [ ])) == expectedBtrbkCommands
          && lib.all (hasOnlyOptions [ "NOPASSWD" ]) (rule.commands or [ ]);

        isKnownRule =
          rule:
          isDefaultRootSetenvRule rule
          || isDefaultWheelSetenvRule rule
          || isAgentMaintenanceRule rule
          || isBtrbkMaintenanceRule rule;

        unexpectedRules = lib.filter (rule: !(isKnownRule rule)) extraRules;
        agentRules = lib.filter isAgentMaintenanceRule extraRules;
      in
      mkResult (agentRules != [ ] && unexpectedRules == [ ])
        "main sudo extraRules must only contain the default SETENV rules, exact agent maintenance allowlist, and btrbk maintenance allowlist";
  };

  mainBackupPathsArePersisted = {
    name = "main backup paths are persisted or on a persistent fs";
    check =
      cfg:
      let
        persistence = cfg.environment.persistence."/persist" or { };
        normalize = entry: key: if builtins.isAttrs entry then entry.${key} else entry;
        persistedDirs = map (d: normalize d "directory") (persistence.directories or [ ]);
        persistedFiles = map (f: normalize f "file") (persistence.files or [ ]);

        subvolOptionFor =
          fs: lib.findFirst (option: lib.hasPrefix "subvol=" option) null (fs.options or [ ]);
        subvolFor =
          fs:
          let
            option = subvolOptionFor fs;
          in
          if option == null then null else lib.removePrefix "subvol=" option;
        persistentRoots = lib.mapAttrsToList (mountPoint: _: mountPoint) (
          lib.filterAttrs (
            _: fs: (fs.fsType or "") == "btrfs" && subvolFor fs != null && subvolFor fs != "/@root"
          ) cfg.fileSystems
        );
        isUnderRoot = root: path: path == root || (root != "/" && lib.hasPrefix "${root}/" path);

        isPersistent =
          path:
          lib.any (root: isUnderRoot root path) persistentRoots
          || lib.elem path persistedDirs
          || lib.elem path persistedFiles
          || lib.any (d: lib.hasPrefix (d + "/") path) persistedDirs;

        offenders = lib.filter (p: !(isPersistent p)) (cfg.services.restic.backups.local.paths or [ ]);
      in
      mkResult (offenders == [ ])
        "backup path(s) not persisted (would be wiped on rollback boot): ${lib.concatStringsSep ", " offenders}";
  };

  mainBtrbkPolicyMatchesLocalSnapshotIntent = {
    name = "main btrbk policy keeps local snapshots scoped and bounded";
    check =
      cfg:
      let
        instance = lib.attrByPath [ "services" "btrbk" "instances" "local" ] null cfg;
        fs = cfg.fileSystems."/.btrfs-root" or null;
        snapshotDirService = cfg.systemd.services.btrbk-local-snapshot-dir or null;
        settings = if instance == null then { } else instance.settings or { };
        volume = lib.attrByPath [ "volume" "/.btrfs-root" ] { } settings;
        subvolumes = volume.subvolume or { };
        expectedSubvolumes = [
          "@home"
          "@persist"
        ];
        actualSubvolumes = builtins.attrNames subvolumes;
        subvolumeCheck = requirePaths actualSubvolumes expectedSubvolumes;
        violations = lib.filter (msg: msg != "") [
          (lib.optionalString (instance == null) "services.btrbk.instances.local must exist")
          (lib.optionalString (
            instance != null && !(instance.snapshotOnly or false)
          ) "services.btrbk.instances.local.snapshotOnly must be true")
          (lib.optionalString (
            instance != null && (instance.onCalendar or null) != "daily"
          ) "services.btrbk.instances.local.onCalendar must be \"daily\"")
          (lib.optionalString (
            instance != null && (settings.snapshot_preserve_min or null) != "2d"
          ) "services.btrbk.instances.local.settings.snapshot_preserve_min must be \"2d\"")
          (lib.optionalString (
            instance != null && (settings.snapshot_preserve or null) != "14d"
          ) "services.btrbk.instances.local.settings.snapshot_preserve must be \"14d\"")
          (lib.optionalString (instance != null && (volume.snapshot_dir or null) != ".snapshots")
            "services.btrbk.instances.local.settings.volume.\"/.btrfs-root\".snapshot_dir must be \".snapshots\""
          )
          (lib.optionalString (instance != null && !subvolumeCheck.passed) subvolumeCheck.message)
          (lib.optionalString (fs == null) "fileSystems.\"/.btrfs-root\" must exist")
          (lib.optionalString (
            fs != null && (fs.fsType or null) != "btrfs"
          ) "fileSystems.\"/.btrfs-root\" must be a btrfs mount")
          (lib.optionalString (
            fs != null && !builtins.elem "subvol=/" (fs.options or [ ])
          ) "fileSystems.\"/.btrfs-root\" must mount the btrfs top-level with subvol=/")
          (lib.optionalString (
            snapshotDirService == null
          ) "systemd.services.btrbk-local-snapshot-dir must exist")
          (lib.optionalString (
            snapshotDirService != null
            && !builtins.elem "btrbk-local.service" (snapshotDirService.requiredBy or [ ])
          ) "systemd.services.btrbk-local-snapshot-dir must be required by btrbk-local.service")
          (lib.optionalString (
            snapshotDirService != null
            && !builtins.elem "btrbk-local.service" (snapshotDirService.before or [ ])
          ) "systemd.services.btrbk-local-snapshot-dir must run before btrbk-local.service")
          (lib.optionalString (
            snapshotDirService != null
            && (snapshotDirService.unitConfig.RequiresMountsFor or null) != "/.btrfs-root"
          ) "systemd.services.btrbk-local-snapshot-dir must require mounts for /.btrfs-root")
        ];
      in
      mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
  };

  homeserverGcpB2BackupUsesCriticalPolicy = {
    name = "homeserver-gcp B2 backup uses critical policy";
    check =
      cfg:
      let
        backup = cfg.services.restic.backups.b2;
        expectedPruneOpts = [
          "--keep-daily 14"
          "--keep-weekly 8"
          "--keep-monthly 6"
          "--keep-yearly 2"
        ];
        pathCheck = requirePaths backup.paths [
          "/var/lib/vaultwarden"
          "/var/lib/grafana"
          "/var/lib/restic-backup-canary"
          "/var/lib/restic-staging/adguardhome"
        ];
        violations = lib.filter (msg: msg != "") [
          (lib.optionalString (
            !(lib.hasPrefix "/run/secrets/" (backup.repositoryFile or ""))
          ) "services.restic.backups.b2.repositoryFile must come from /run/secrets/*")
          (lib.optionalString (
            !(lib.hasPrefix "/run/secrets/" (backup.passwordFile or ""))
          ) "services.restic.backups.b2.passwordFile must come from /run/secrets/*")
          (lib.optionalString (
            !(lib.hasPrefix "/run/secrets/" (backup.environmentFile or ""))
          ) "services.restic.backups.b2.environmentFile must come from /run/secrets/*")
          (lib.optionalString (!backup.initialize) "services.restic.backups.b2.initialize must be true")
          (lib.optionalString (
            backup.pruneOpts != expectedPruneOpts
          ) "services.restic.backups.b2.pruneOpts must match the critical retention class")
          (lib.optionalString (
            (backup.timerConfig.OnCalendar or null) != "daily"
          ) "services.restic.backups.b2.timerConfig.OnCalendar must be \"daily\"")
          (lib.optionalString (!pathCheck.passed) pathCheck.message)
        ];
      in
      mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
  };

  commonSystemInvariants = [
    invariants.hasStateVersion
    nixpkgsRegistryPinnedToFlakeInput
    {
      name = "impermanent hosts have matching disko config";
      check = invariants.checkImpermanentHostHasDiskoConfig;
    }
  ];

  mainAccessInvariants = [
    {
      name = "no passwordless sudo";
      check =
        cfg: require cfg.security.sudo.wheelNeedsPassword "security.sudo.wheelNeedsPassword must be true";
    }
    mainAgentMaintenanceSudoAllowlist
    invariants.mainSshIsTailnetOnly
    invariants.mainUsbguardIsDenyDefault
    {
      name = "anonymous specialisation persistence stays minimal";
      check = invariants.checkAnonymousSpecialisationPersistence;
    }
    {
      name = "Mullvad and Tailscale coexistence assumptions hold";
      check = invariants.checkMullvadTailscaleCoexistence;
    }
  ];

  mainExperienceInvariants = [
    mainInteractiveShellUsesNixIndexAndComma
    invariants.obsClientUsesCanonicalUsername
  ];

  mainBackupInvariants = [
    invariants.mainLocalBackupProtectsCriticalPaths
    mainBackupPathsArePersisted
    mainBtrbkPolicyMatchesLocalSnapshotIntent
  ];

  homeserverAccessInvariants = invariants.deployTargetAccessAssertions ++ [
    invariants.homeserverSshAndHttpsNotGloballyOpen
    invariants.homeserverSshAndHttpsTailscaleOnly
  ];

  homeserverBackupInvariants = [
    homeserverGcpB2BackupUsesCriticalPolicy
  ];

  homeserverAlertDeliveryInvariants = [
    {
      name = "alerting stack has direct failed-unit webhook fallback";
      check =
        cfg:
        let
          notifier = cfg.services.systemd-failure-notify;
          expectedUnits = [
            "heartbeat-ping"
            "mimir"
            "nginx"
            "prometheus"
            "prometheus-node-exporter"
            "tailscaled"
          ];
          actualUnits = lib.sort builtins.lessThan notifier.services;
          violations = lib.filter (msg: msg != "") [
            (lib.optionalString (!notifier.enable) "services.systemd-failure-notify.enable must be true")
            (lib.optionalString (
              notifier.webhookUrlFile != "/run/secrets/alertmanager_webhook_url"
            ) "services.systemd-failure-notify.webhookUrlFile must use /run/secrets/alertmanager_webhook_url")
            (lib.optionalString (
              actualUnits != expectedUnits
            ) "services.systemd-failure-notify.services must cover the alerting/reachability stack")
          ];
        in
        mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
    }
  ];

  # mac is a deploy-rs target like homeserver-gcp (passwordless wheel, SSH tailnet-only)
  # but does not publish HTTPS, so only SSH ports are checked.
  macAccessInvariants = invariants.deployTargetAccessAssertions ++ [
    invariants.macSshNotGloballyOpen
    invariants.macSshTailscaleOnly
  ];

  gcpBuilderAccessInvariants = invariants.deployTargetBaseAccessAssertions ++ [
    invariants.gcpBuilderSshTailscaleOnly
    invariants.gcpBuilderUsersAreKeyOnly
  ];

  # gcp-agent shares gcp-builder's SSH posture (tailnet-only, key-only login)
  # but, unlike every other GCP target, keeps NARROW sudo: it runs autonomous
  # Claude Code sessions, so it must not grant deploy-rs-style broad NOPASSWD —
  # a session compromise must not be trivially root. The two SSH checks are
  # host-agnostic; reuse them. Heavy builds offload to gcp-builder, so this box
  # never needs activation sudo.
  gcpAgentAccessInvariants = [
    invariants.gcpBuilderSshTailscaleOnly
    invariants.gcpBuilderUsersAreKeyOnly
    {
      name = "gcp-agent keeps wheelNeedsPassword (narrow sudo)";
      check =
        cfg:
        invariants.require cfg.security.sudo.wheelNeedsPassword "security.sudo.wheelNeedsPassword must stay true on gcp-agent (narrow sudo; it runs autonomous sessions and does not deploy)";
    }
  ];

  # Lint the Mimir ruler alert rules with promtool. Renders the exact same
  # shared data the observability module deploys (lib/observability-alerts.nix)
  # so a typo in a metric name, label, or expr fails the light lane instead of
  # silently shipping a non-firing rule.
  alertData = import ../lib/observability-alerts.nix;
  rulesYaml = (pkgs.formats.yaml { }).generate "infrastructure-alerts.yaml" alertData.rules;
  observabilityAlertsLint =
    pkgs.runCommand "observability-alerts-lint" { nativeBuildInputs = [ pkgs.prometheus.cli ]; }
      ''
        promtool check rules ${rulesYaml}
        touch $out
      '';

  observabilityStackFixture =
    let
      systemConfig = lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          ../modules/nixos/profiles/observability
          (
            { pkgs, ... }:
            {
              networking.hostName = "observability-fixture";
              system.stateVersion = "26.05";

              profiles.observability = {
                enable = true;
                grafana = {
                  enable = true;
                  adminPasswordFile = pkgs.writeText "grafana-admin-password" "test-password";
                };
                loki.enable = true;
                tempo.enable = true;
                mimir.enable = true;
                collectors = {
                  metrics.enable = true;
                  logs.enable = true;
                  traces.enable = true;
                };
              };
            }
          )
        ];
      };
      evaluated = {
        grafana = systemConfig.config.services.grafana.enable;
        loki = systemConfig.config.services.loki.enable;
        mimir = systemConfig.config.services.mimir.enable;
        tempo = systemConfig.config.services.tempo.enable;
        prometheus = systemConfig.config.services.prometheus.enable;
      };
    in
    pkgs.writeText "observability-stack-fixture.json" (builtins.toJSON evaluated);

  observabilityClientFixture =
    let
      passwordFile = pkgs.writeText "observability-ingest-password" "test-password";
      envFile = pkgs.writeText "otel-env" "BASICAUTH_PASSWORD=test-password";
      systemConfig = lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          ../modules/nixos/profiles/observability
          ../modules/nixos/profiles/observability-client.nix
          {
            networking.hostName = "observability-client-fixture";
            system.stateVersion = "26.05";

            profiles.observability-client = {
              enable = true;
              remoteEndpoint = {
                scheme = "https";
                host = "observability.example.ts.net";
                metricsPath = "/ingest/metrics";
                logsPath = "/ingest/logs";
                tracesPath = "/ingest/traces";
              };
              ingestAuth = {
                inherit passwordFile;
                serviceEnvironmentFile = envFile;
              };
            };
          }
        ];
      };
      evaluated = {
        metricsURL = (builtins.head systemConfig.config.services.prometheus.remoteWrite).url;
        logsEnabled = systemConfig.config.services.alloy.enable;
        traceEndpoint =
          systemConfig.config.services.opentelemetry-collector.settings.exporters.otlphttp.endpoint;
      };
    in
    pkgs.writeText "observability-client-fixture.json" (builtins.toJSON evaluated);

  observabilityDashboardBackendAssertionFixture =
    let
      dash = import ../lib/dashboards.nix;
      passwordFile = pkgs.writeText "grafana-admin-password" "test-password";
      badEvaluation = builtins.tryEval (
        builtins.deepSeq
          (lib.nixosSystem {
            system = pkgs.stdenv.hostPlatform.system;
            modules = [
              ../modules/nixos/profiles/observability
              {
                networking.hostName = "observability-dashboard-backend-mismatch-fixture";
                system.stateVersion = "26.05";

                profiles.observability = {
                  enable = true;
                  grafana = {
                    enable = true;
                    adminPasswordFile = passwordFile;
                  };
                  mimir.enable = false;
                  dashboards.mimir-without-backend = {
                    enable = true;
                    definition = dash.mkDashboard {
                      uid = "mimir-without-backend";
                      title = "Mimir Without Backend";
                      panels = [
                        (dash.statPanel {
                          id = 1;
                          title = "Metric";
                          ds = dash.mimirDS;
                          gridPos = dash.gridPos { };
                          targets = [
                            (dash.target { expr = "up"; })
                          ];
                        })
                      ];
                    };
                  };
                };
              }
            ];
          }).config.system.build.toplevel.drvPath
          true
      );
    in
    if badEvaluation.success then
      throw "observability dashboard/backend assertion fixture unexpectedly evaluated"
    else
      pkgs.runCommand "observability-dashboard-backend-assertion-fixture" { } "touch $out";

  # Evaluates the exact `services.hardened.nginx.extraConfig` snippet shown in
  # docs/modules/services-hardened.md against nixpkgs only — no `hosts/` import,
  # no real hostnames or secrets — proving the copyable example works standalone.
  servicesHardenedExampleFixture =
    let
      systemConfig = lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          ../modules/nixos/services/hardened.nix
          (
            { pkgs, ... }:
            {
              networking.hostName = "services-hardened-example-fixture";
              system.stateVersion = "26.05";

              systemd.services.nginx.serviceConfig = {
                ExecStart = "${pkgs.coreutils}/bin/true";
                Type = "oneshot";
              };

              services.hardened.nginx.extraConfig = {
                CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";
                AmbientCapabilities = "CAP_NET_BIND_SERVICE";
                ReadWritePaths = [
                  "/var/cache/nginx"
                  "/var/log/nginx"
                  "/var/lib/nginx/certs"
                ];
              };
            }
          )
        ];
      };
      serviceConfig = systemConfig.config.systemd.services.nginx.serviceConfig;
      evaluated = {
        capabilityBoundingSet = serviceConfig.CapabilityBoundingSet;
        ambientCapabilities = serviceConfig.AmbientCapabilities;
        readWritePaths = serviceConfig.ReadWritePaths;
        # Forced baseline keys must still apply on top of the documented example.
        privateTmp = serviceConfig.PrivateTmp;
        protectSystem = serviceConfig.ProtectSystem;
      };
    in
    pkgs.writeText "services-hardened-example-fixture.json" (builtins.toJSON evaluated);

  # Evaluates both `examples/mini-fleet` hosts against nixpkgs only — the same
  # `nixosModules.*` paths the example's own `flake.nix` imports as public
  # flake outputs, never `hosts/`. Mirrors the `servicesHardenedExampleFixture`
  # / `observability-*-fixture` pattern: prove the copyable example evaluates
  # standalone so it cannot silently rot when a layered module changes.
  miniFleetExampleFixture =
    let
      workstation = lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          ../examples/mini-fleet/hosts/workstation-example
          ../modules/nixos/profiles/desktop.nix
          ../modules/nixos/profiles/security.nix
          inputs.home-manager.nixosModules.home-manager
          {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              users.demo = {
                home.stateVersion = "26.05";
                imports = [ ../home/profiles/base.nix ];
              };
            };
          }
        ];
      };
      server = lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          ../examples/mini-fleet/hosts/server-example
          ../modules/nixos/services/hardened.nix
          ../modules/nixos/profiles/security.nix
          ../modules/nixos/profiles/observability
          ../modules/nixos/profiles/observability-client.nix
        ];
      };
      evaluated = {
        workstationHostName = workstation.config.networking.hostName;
        workstationHasDesktop = workstation.config.programs.hyprland.enable;
        workstationFirewallEnabled = workstation.config.networking.firewall.enable;
        workstationHomeHasBasePackages = workstation.config.home-manager.users.demo.home.packages != [ ];
        serverHostName = server.config.networking.hostName;
        serverServiceCapabilityBoundingSet =
          server.config.systemd.services.demo-app.serviceConfig.CapabilityBoundingSet;
        serverMetricsURL = (builtins.head server.config.services.prometheus.remoteWrite).url;
      };
    in
    pkgs.writeText "mini-fleet-example-fixture.json" (builtins.toJSON evaluated);

  mkSopsBootstrapCheck =
    hostName: secretsDir:
    let
      hasKey = builtins.pathExists (secretsDir + "/ssh_host_ed25519_key.enc");
      hasPub = builtins.pathExists (secretsDir + "/ssh_host_ed25519_key.pub.enc");
    in
    if hasKey && hasPub then
      pkgs.runCommand "${hostName}-sops-bootstrap-check" { } "touch $out"
    else
      pkgs.runCommand "${hostName}-sops-bootstrap-check" { } ''
        echo "${hostName} sops bootstrap incomplete — missing pre-baked host key files:"
        ${lib.optionalString (!hasKey) ''echo "  hosts/${hostName}/secrets/ssh_host_ed25519_key.enc"''}
        ${lib.optionalString (!hasPub) ''echo "  hosts/${hostName}/secrets/ssh_host_ed25519_key.pub.enc"''}
        exit 1
      '';

  # Invariant list shared by the full `main` closure and the `main-ci`
  # closure CI actually builds, so a `profiles.ci`-gated change to a
  # security option cannot slip past either variant.
  mainInvariants =
    commonSystemInvariants
    ++ mainAccessInvariants
    ++ mainExperienceInvariants
    ++ mainBackupInvariants
    ++ registryAssertionsFor "main";

  registrySecurityInvariants = [
    {
      name = "SOPS recipients match active host registry";
      check = _: invariants.checkSopsRecipientParity hostRegistry (builtins.readFile ../.sops.yaml);
    }
    {
      name = "deploy targets have tailnet addresses";
      check = _: invariants.checkDeployTargetsHaveTailnetAddresses hostRegistry;
    }
  ];
in
{
  invariantChecks = {
    invariants-registry-security =
      invariants.mkInvariantCheck "registry-security" registrySecurityInvariants
        { };

    invariants-main = invariants.mkInvariantCheck "main" mainInvariants allNixosConfigs.main.config;

    # CI ships `main-ci` (profiles.ci = true; skipHeavyPackages = true), not
    # the full `main` closure; pin the same invariants to it so the gated
    # build is what gets validated.
    invariants-main-ci =
      invariants.mkInvariantCheck "main-ci" mainInvariants
        ciNixosConfigs.main-ci.config;

    invariants-homeserver-gcp = invariants.mkInvariantCheck "homeserver-gcp" (
      commonSystemInvariants
      ++ homeserverAccessInvariants
      ++ homeserverBackupInvariants
      ++ homeserverAlertDeliveryInvariants
      ++ registryAssertionsFor "homeserver-gcp"
    ) ciNixosConfigs.homeserver-gcp.config;

    invariants-gcp-builder = invariants.mkInvariantCheck "gcp-builder" (
      commonSystemInvariants ++ gcpBuilderAccessInvariants ++ registryAssertionsFor "gcp-builder"
    ) allNixosConfigs.gcp-builder.config;

    invariants-gcp-agent = invariants.mkInvariantCheck "gcp-agent" (
      commonSystemInvariants ++ gcpAgentAccessInvariants ++ registryAssertionsFor "gcp-agent"
    ) allNixosConfigs.gcp-agent.config;

    invariants-mac = invariants.mkInvariantCheck "mac" (
      commonSystemInvariants ++ macAccessInvariants ++ registryAssertionsFor "mac"
    ) allNixosConfigs.mac.config;

    homeserver-gcp-sops-bootstrap = mkSopsBootstrapCheck "homeserver-gcp" ../hosts/homeserver-gcp/secrets;

    mac-sops-bootstrap = mkSopsBootstrapCheck "mac" ../hosts/mac/secrets;

    gcp-agent-sops-bootstrap = mkSopsBootstrapCheck "gcp-agent" ../hosts/gcp-agent/secrets;

    observability-alerts-lint = observabilityAlertsLint;
    observability-stack-fixture = observabilityStackFixture;
    observability-client-fixture = observabilityClientFixture;
    observability-dashboard-backend-assertion-fixture = observabilityDashboardBackendAssertionFixture;
    services-hardened-example-fixture = servicesHardenedExampleFixture;
    mini-fleet-example-fixture = miniFleetExampleFixture;
  };

  ciTestsFor = system: {
    homeserver-gcp-smoke = import ../tests/nixos/homeserver-gcp-smoke.nix {
      inherit nixpkgs system inputs;
    };
    profile-security = import ../tests/nixos/profile-security.nix {
      inherit nixpkgs system;
    };
    profile-observability = import ../tests/nixos/profile-observability.nix {
      inherit nixpkgs system;
    };
    profile-hardening = import ../tests/nixos/profile-hardening.nix {
      inherit nixpkgs system;
    };
  };
}
