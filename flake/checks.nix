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

  checkPythonFiles = import ../home/profiles/python-development-check.nix { inherit lib pkgs; };

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

  rollbackRootInitrdToolsAvailable = {
    name = "rollback-root initrd tools are available";
    check =
      cfg:
      let
        rollbackEnabled = cfg.profiles.impermanence.rollbackRoot.enable or false;
        initrdBinNames = map lib.getName (cfg.boot.initrd.systemd.initrdBin or [ ]);
        requiredTools = [
          "btrfs-progs"
          "findutils"
          "gnused"
        ];
        missingTools = lib.filter (tool: !(builtins.elem tool initrdBinNames)) requiredTools;
      in
      mkResult (
        !rollbackEnabled || missingTools == [ ]
      ) "rollback-root.service needs initrdBin package(s): ${lib.concatStringsSep ", " missingTools}";
  };

  homeserverGcpB2BackupUsesCriticalPolicy = {
    name = "homeserver-gcp B2 backup uses critical policy";
    check =
      cfg:
      let
        backup = cfg.services.restic.backups.b2;
        # Same source modules/nixos/profiles/backup.nix uses, so this can't
        # drift out of sync with the policy that's actually applied.
        # Pinned literally (not read from lib/backup-policy.nix): a shared
        # source would let a retention cut change policy and expectation together.
        expectedPruneOpts = [
          "--group-by host"
          "--keep-daily 14"
          "--keep-weekly 8"
          "--keep-monthly 6"
          "--keep-yearly 2"
        ];
        pathCheck = requirePaths backup.paths [
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

  # An impermanent host that loses /var/lib/tailscale re-registers a new node
  # identity on every boot (new IP, orphaned device, ACL tags lost).
  tailscaleStateIsPersisted = {
    name = "impermanent tailscale hosts persist /var/lib/tailscale";
    check =
      cfg:
      let
        dirs = map (d: if builtins.isAttrs d then d.directory else d) (
          lib.concatMap (p: p.directories or [ ]) (lib.attrValues (cfg.environment.persistence or { }))
        );
      in
      mkResult (
        !(cfg.profiles.impermanence.rollbackRoot.enable or false)
        || !cfg.services.tailscale.enable
        || builtins.elem "/var/lib/tailscale" dirs
      ) "/var/lib/tailscale must be persisted on impermanent hosts that run Tailscale";
  };

  mainNoGloballyOpenPorts = {
    name = "main opens no ports on all interfaces";
    check =
      cfg:
      let
        tcp = invariants.firewallPorts "TCP" cfg.networking.firewall;
        # mDNS (avahi) and the WireGuard port tailscaled listens on are the only
        # sanctioned global UDP ports.
        udp = lib.subtractLists [ 5353 41641 ] (invariants.firewallPorts "UDP" cfg.networking.firewall);
      in
      mkResult (tcp == [ ] && udp == [ ])
        "unexpected globally open ports (open them per-interface): tcp=${builtins.toJSON tcp} udp=${builtins.toJSON udp}";
  };

  commonSystemInvariants = [
    invariants.observabilityStaysMinimal
    tailscaleStateIsPersisted
    invariants.tailscaleAutoconnectNormalizesPrefs
    nixpkgsRegistryPinnedToFlakeInput
    rollbackRootInitrdToolsAvailable
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
    invariants.mainAgentMaintenanceSudoAllowlist
    invariants.mainSshIsTailnetOnly
    mainNoGloballyOpenPorts
    invariants.mainUsbguardIsDenyDefault
    {
      name = "Mullvad and Tailscale coexistence assumptions hold";
      check = invariants.checkMullvadTailscaleCoexistence;
    }
  ];

  mainExperienceInvariants = [
    invariants.mainBluetoothDriverHasBootTrigger
    mainInteractiveShellUsesNixIndexAndComma
    invariants.obsClientUsesCanonicalUsername
  ];

  mainBackupInvariants = [
    invariants.mainLocalBackupProtectsCriticalPaths
    invariants.persistentNetworkTimersSurviveResume
    mainBackupPathsArePersisted
    mainBtrbkPolicyMatchesLocalSnapshotIntent
  ];

  runnerChecks = import ../hosts/homeserver-gcp/github-runner-checks.nix { inherit lib; };

  homeserverAccessInvariants = invariants.deployTargetAccessAssertions ++ [
    invariants.homeserverSshAndHttpsTailscaleOnly
    runnerChecks.selfSwitch
    runnerChecks.runbook
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
            "alertmanager"
            "heartbeat-ping"
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

  onDemandAccessInvariants = invariants.deployTargetBaseAccessAssertions ++ [
    invariants.onDemandSshTailscaleOnly
    invariants.onDemandUsersAreKeyOnly
  ];

  # Lint the Prometheus alert rules with promtool. Renders the exact same
  # shared data the observability module deploys (lib/observability-alerts.nix)
  # so a typo in a metric name, label, or expr fails the light lane instead of
  # silently shipping a non-firing rule.
  alertData = import ../lib/observability-alerts.nix;
  rulesYaml = (pkgs.formats.yaml { }).generate "infrastructure-alerts.yaml" alertData.rules;
  requiredAlerts = [
    "SystemdUnitFailed"
    "ResticBackupStale"
    "ResticCheckStale"
    "ResticRestoreCanaryStale"
    "HeartbeatPingStale"
    "BlackboxProbeFailed"
    "TLSCertificateExpiresSoon"
    "BackupEvidenceMissing"
  ];

  # promtool unit tests for BackupEvidenceMissing: a reporting host missing
  # one expected timestamp alerts after the hold, the others stay quiet, and
  # a host that is not reporting at all (e.g. powered off) never alerts.
  missingEvidenceTests =
    let
      host = "homeserver-gcp";
      expected = alertData.expectedBackupEvidence.${host};
      missing = lib.last expected;
      series = name: {
        series = ''${name}{host="${host}",instance="127.0.0.1:9100",job="node"}'';
        values = "1x150";
      };
    in
    (pkgs.formats.yaml { }).generate "missing-evidence-tests.yaml" {
      rule_files = [ "rules.yaml" ];
      evaluation_interval = "1m";
      tests = [
        {
          interval = "1m";
          input_series = map series ([ "node_boot_time_seconds" ] ++ lib.init expected);
          alert_rule_test = [
            {
              eval_time = "30m";
              alertname = "BackupEvidenceMissing";
              exp_alerts = [ ];
            }
            {
              eval_time = "90m";
              alertname = "BackupEvidenceMissing";
              exp_alerts = [
                {
                  exp_labels = {
                    severity = "warning";
                    inherit host;
                    metric = missing;
                  };
                  exp_annotations = {
                    summary = "No ${missing} on ${host}";
                    description = "${host} is reporting metrics but has no ${missing} series, so the matching stale alert cannot fire. The job has never succeeded or its textfile was removed.";
                  };
                }
              ];
            }
          ];
        }
        {
          interval = "1m";
          input_series = [ ];
          alert_rule_test = [
            {
              eval_time = "90m";
              alertname = "BackupEvidenceMissing";
              exp_alerts = [ ];
            }
          ];
        }
      ];
    };

  # Apply each retention class from lib/backup-policy.nix to dated snapshots in
  # a scratch repository and compare the survivors with a hand-worked oracle.
  # The path list changes partway through the series, so a lost
  # `--group-by host` would keep the older group intact and fail here.
  #
  # Series: 1-20 Nov 2026 daily (paths a for 1-10, a+b for 11-20), plus
  # 15 Sep, 15 Jun, 15 Dec 2025 and 15 Dec 2024. ISO weeks end on 1, 8, 15
  # and 22 Nov. restic counts from the newest snapshot, not the clock.
  backupRetentionBehaviour =
    let
      policy = import ../lib/backup-policy.nix;
      novDays = lib.genList (i: "2026-11-${lib.fixedWidthNumber 2 (i + 1)}") 20;
      older = [
        "2024-12-15"
        "2025-12-15"
        "2026-06-15"
        "2026-09-15"
      ];
      # critical: 14 daily keeps 7-20 Nov; 8 weekly adds 1 Nov and all four
      # older dates; monthly and yearly add nothing new.
      expected.critical = older ++ [ "2026-11-01" ] ++ lib.sublist 6 14 novDays;
      # standard: 7 daily keeps 14-20 Nov; 4 weekly adds 1 and 8 Nov
      # (15 Nov is already kept); 3 monthly adds 15 Sep and 15 Jun.
      expected.standard = [
        "2026-06-15"
        "2026-09-15"
        "2026-11-01"
        "2026-11-08"
      ]
      ++ lib.sublist 13 7 novDays;
      runClass = class: ''
        export RESTIC_REPOSITORY=$PWD/repo-${class}
        restic init --quiet
        for d in ${lib.escapeShellArgs older} ${lib.escapeShellArgs (lib.sublist 0 10 novDays)}; do
          restic backup --quiet --host fixture --time "$d 12:00:00" src/a
        done
        for d in ${lib.escapeShellArgs (lib.sublist 10 10 novDays)}; do
          restic backup --quiet --host fixture --time "$d 12:00:00" src/a src/b
        done
        restic forget --quiet ${lib.concatStringsSep " " policy.${class}}
        restic snapshots --json | jq -r '.[].time[:10]' | sort > kept-${class}
        printf '%s\n' ${lib.escapeShellArgs expected.${class}} | sort > want-${class}
        diff -u want-${class} kept-${class}
      '';
    in
    pkgs.runCommand "backup-retention-behaviour"
      {
        nativeBuildInputs = [
          pkgs.restic
          pkgs.jq
        ];
      }
      ''
        export RESTIC_PASSWORD=fixture HOME=$PWD
        mkdir -p src/a src/b
        echo a > src/a/file
        echo b > src/b/file
        ${runClass "critical"}
        ${runClass "standard"}
        touch $out
      '';

  observabilityAlertsLint =
    pkgs.runCommand "observability-alerts-lint" { nativeBuildInputs = [ pkgs.prometheus.cli ]; }
      ''
        promtool check rules ${rulesYaml}
        # Deleting an alert is not a lint error; pin the ones that guard backups,
        # failed units and liveness so removing one fails here.
        for alert in ${lib.escapeShellArgs requiredAlerts}; do
          grep -q "alert: $alert\$" ${rulesYaml} || { echo "missing required alert: $alert" >&2; exit 1; }
        done
        cp ${rulesYaml} rules.yaml
        cp ${missingEvidenceTests} tests.yaml
        promtool test rules tests.yaml
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
                alerts.enable = true;
                collectors = {
                  metrics.enable = true;
                  logs.enable = true;
                };
              };
            }
          )
        ];
      };
      evaluated = {
        grafana = systemConfig.config.services.grafana.enable;
        loki = systemConfig.config.services.loki.enable;
        alertmanager = systemConfig.config.services.prometheus.alertmanager.enable;
        prometheus = systemConfig.config.services.prometheus.enable;
      };
      expected = {
        grafana = true;
        loki = true;
        alertmanager = true;
        prometheus = true;
      };
    in
    assert lib.assertMsg (
      evaluated == expected
    ) "observability-stack-fixture: ${builtins.toJSON evaluated}";
    pkgs.writeText "observability-stack-fixture.json" (builtins.toJSON evaluated);

  observabilityClientFixture =
    let
      passwordFile = pkgs.writeText "observability-ingest-password" "test-password";
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
                # scheme intentionally unset: the default must be https.
                host = "observability.example.ts.net";
                metricsPath = "/ingest/metrics";
                logsPath = "/ingest/logs";
              };
              ingestAuth = {
                inherit passwordFile;
              };
            };
          }
        ];
      };
      evaluated = {
        metricsURL = (builtins.head systemConfig.config.services.prometheus.remoteWrite).url;
        logsEnabled = systemConfig.config.services.alloy.enable;
      };
      expected = {
        metricsURL = "https://observability.example.ts.net/ingest/metrics";
        logsEnabled = true;
      };
    in
    assert lib.assertMsg (
      evaluated == expected
    ) "observability-client-fixture: ${builtins.toJSON evaluated}";
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
                  collectors.metrics.enable = false;
                  dashboards.metrics-without-backend = {
                    enable = true;
                    definition = dash.mkDashboard {
                      uid = "metrics-without-backend";
                      title = "Metrics Without Backend";
                      panels = [
                        (dash.statPanel {
                          id = 1;
                          title = "Metric";
                          ds = dash.prometheusDS;
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
      expected = {
        capabilityBoundingSet = "CAP_NET_BIND_SERVICE";
        ambientCapabilities = "CAP_NET_BIND_SERVICE";
        readWritePaths = [
          "/var/cache/nginx"
          "/var/log/nginx"
        ];
        privateTmp = true;
        protectSystem = "strict";
      };
    in
    assert lib.assertMsg (
      evaluated == expected
    ) "services-hardened-example-fixture: ${builtins.toJSON evaluated}";
    pkgs.writeText "services-hardened-example-fixture.json" (builtins.toJSON evaluated);

  # Evaluates `nixosModules.profiles-base` standalone: no observability module
  # imported or enabled, and no `inputs`/`self` specialArgs. The public export
  # must not depend on observability internals or this private flake's argument
  # names.
  profilesBaseStandaloneFixture =
    let
      systemConfig = lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          ../modules/nixos/profiles/base.nix
          {
            networking.hostName = "profiles-base-standalone-fixture";
            system.stateVersion = "26.05";
          }
        ];
      };
      evaluated = {
        configurationRevision = systemConfig.config.system.configurationRevision;
        hasNixpkgsRegistry = systemConfig.config.nix.registry ? nixpkgs;
        hasExportSystemMetadata = systemConfig.config.system.activationScripts ? exportSystemMetadata;
        zramSwap = systemConfig.config.zramSwap.enable;
      };
      expected = {
        configurationRevision = null;
        hasNixpkgsRegistry = true;
        hasExportSystemMetadata = false;
        zramSwap = true;
      };
    in
    assert lib.assertMsg (
      evaluated == expected
    ) "profiles-base-standalone-fixture: ${builtins.toJSON evaluated}";
    pkgs.writeText "profiles-base-standalone-fixture.json" (builtins.toJSON evaluated);

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
      workstationToplevel = builtins.tryEval (
        builtins.deepSeq workstation.config.system.build.toplevel.drvPath true
      );
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
      serverToplevel = builtins.tryEval (
        builtins.deepSeq server.config.system.build.toplevel.drvPath true
      );
      evaluated = {
        workstationHostName = workstation.config.networking.hostName;
        workstationHasDesktop = workstation.config.programs.hyprland.enable;
        workstationFirewallEnabled = workstation.config.networking.firewall.enable;
        workstationHomeHasBasePackages = workstation.config.home-manager.users.demo.home.packages != [ ];
        workstationToplevelBuildable = workstationToplevel.success;
        serverToplevelBuildable = serverToplevel.success;
        serverHostName = server.config.networking.hostName;
        serverServiceCapabilityBoundingSet =
          server.config.systemd.services.demo-app.serviceConfig.CapabilityBoundingSet;
        serverMetricsURL = (builtins.head server.config.services.prometheus.remoteWrite).url;
      };
    in
    if !workstationToplevel.success then
      throw "mini-fleet example fixture: workstation system.build.toplevel failed to evaluate (e.g. failing NixOS assertions)"
    else if !serverToplevel.success then
      throw "mini-fleet example fixture: server system.build.toplevel failed to evaluate (e.g. failing NixOS assertions)"
    else if evaluated.serverMetricsURL != "https://observability.example.ts.net/ingest/metrics" then
      throw "mini-fleet example fixture: unexpected server metrics URL ${evaluated.serverMetricsURL}"
    else if evaluated.serverServiceCapabilityBoundingSet != "" then
      throw "mini-fleet example fixture: demo-app must drop all capabilities"
    else
      pkgs.writeText "mini-fleet-example-fixture.json" (builtins.toJSON evaluated);

  mkSopsBootstrapCheck =
    hostName: secretsDir:
    let
      hasKey = builtins.pathExists (secretsDir + "/ssh_host_ed25519_key.enc");
      hasPub = builtins.pathExists (secretsDir + "/ssh_host_ed25519_key.pub.enc");
    in
    if hasKey && hasPub then
      # An empty or truncated file (a failed `sops -e > out.enc`) exists but is
      # useless; require non-empty sops-encrypted content. No key material needed.
      pkgs.runCommand "${hostName}-sops-bootstrap-check" { } ''
        for f in ${secretsDir + "/ssh_host_ed25519_key.enc"} ${
          secretsDir + "/ssh_host_ed25519_key.pub.enc"
        }; do
          if [ ! -s "$f" ] || ! grep -q 'ENC\[' "$f"; then
            echo "${hostName} sops bootstrap: empty or non-sops file: $f" >&2
            exit 1
          fi
        done
        touch $out
      ''
    else
      pkgs.runCommand "${hostName}-sops-bootstrap-check" { } ''
        echo "${hostName} sops bootstrap incomplete — missing pre-baked host key files:"
        ${lib.optionalString (!hasKey) ''echo "  hosts/${hostName}/secrets/ssh_host_ed25519_key.enc"''}
        ${lib.optionalString (!hasPub) ''echo "  hosts/${hostName}/secrets/ssh_host_ed25519_key.pub.enc"''}
        exit 1
      '';

  # Host-specific invariant overlays, layered on top of the generated
  # baseline (commonSystemInvariants ++ registryAssertionsFor "<host>") for
  # every hostRegistry entry below. A registry host with no overlay entry
  # still gets the baseline, so adding a host here is optional, not required.
  hostInvariantOverlays = {
    main = mainAccessInvariants ++ mainExperienceInvariants ++ mainBackupInvariants;
    "homeserver-gcp" =
      homeserverAccessInvariants ++ homeserverBackupInvariants ++ homeserverAlertDeliveryInvariants;
    "gcp-builder" = onDemandAccessInvariants;
    "gcp-worker" = onDemandAccessInvariants ++ [ invariants.workerJobsUserUnprivileged ];
  };

  # Registry policy follows the host identity. Both option metadata and values
  # must come from the particular system under evaluation (including main-ci).
  hostInvariantCheck =
    checkName: hostName: evaluated:
    invariants.mkInvariantCheck checkName (
      commonSystemInvariants
      ++ [ (invariants.stateVersionExplicitlySet evaluated.options) ]
      ++ registryAssertionsFor hostName
      ++ (hostInvariantOverlays.${hostName} or [ ])
    ) evaluated.config;

  # Hosts needing a pre-baked SSH host key for nixos-anywhere/deploy-rs
  # bootstrap: deploy-rs targets (`deploy` present) that are sops-enabled
  # (`sops != false`). `gcp-builder` is excluded via `sops = false`; `main` is
  # excluded because it has no `deploy` entry and never carries a pre-baked
  # host key.
  sopsBootstrapHostNames = builtins.attrNames (
    lib.filterAttrs (_: cfg: (cfg ? deploy) && (cfg.sops or true) != false) hostRegistry
  );

  # Baseline `invariants-<host>` check for every hostRegistry entry, so a new
  # host automatically gets merge-gate coverage without touching this file.
  generatedInvariantChecks = lib.mapAttrs' (
    hostName: _:
    lib.nameValuePair "invariants-${hostName}" (
      hostInvariantCheck hostName hostName allNixosConfigs.${hostName}
    )
  ) hostRegistry;

  # `<host>-sops-bootstrap` check for every sopsBootstrapHostNames entry.
  generatedSopsBootstrapChecks = lib.listToAttrs (
    map (
      hostName:
      lib.nameValuePair "${hostName}-sops-bootstrap" (
        mkSopsBootstrapCheck hostName (../hosts + "/${hostName}/secrets")
      )
    ) sopsBootstrapHostNames
  );

  registrySecurityInvariants = [
    {
      name = "SOPS recipients match active host registry";
      check = _: invariants.checkSopsRecipientParity hostRegistry (builtins.readFile ../.sops.yaml);
    }
    {
      name = "deploy targets have tailnet addresses";
      check = _: invariants.checkDeployTargetsHaveTailnetAddresses hostRegistry;
    }
    {
      name = "deploy-rs never connects as root";
      check =
        _:
        let
          rootTargets = builtins.attrNames (
            lib.filterAttrs (_: m: (m.deploy.sshUser or null) == "root") hostRegistry
          );
        in
        mkResult (rootTargets == [ ]) "deploy.sshUser must not be root: ${builtins.toJSON rootTargets}";
    }
    {
      # Reviewed tailnet grants (srcTag->dstTag:port). Any widening or removal
      # of an acceptFrom entry changes the ACL; update this list deliberately.
      name = "tailnet grants match the reviewed set";
      check =
        _:
        let
          actual = lib.sort builtins.lessThan (
            lib.unique (
              lib.concatLists (
                lib.mapAttrsToList (
                  _: m:
                  lib.concatLists (
                    lib.mapAttrsToList (src: ports: map (p: "${src}->${m.tailscale.tag}:${toString p}") ports) (
                      m.tailscale.acceptFrom or { }
                    )
                  )
                ) (lib.filterAttrs (_: m: m ? tailscale) hostRegistry)
              )
            )
          );
          # KDE Connect: link port 1716 plus the 1739-1764 transfer range.
          phoneKdeConnect = map (p: "phone->workstation:${toString p}") (
            [ 1716 ] ++ builtins.genList (i: 1739 + i) 26
          );
          reviewed = lib.sort builtins.lessThan (
            phoneKdeConnect
            ++ [
              "builder->server:53"
              "ci->server:22"
              "ci-builder->builder:22"
              "workstation->builder:22"
              "workstation->server:22"
              "workstation->server:3001"
              "workstation->server:443"
              "workstation->server:53"
              "workstation->worker:22"
              "workstation->workstation:22"
              "worker->server:53"
            ]
          );
        in
        mkResult (
          actual == reviewed
        ) "tailnet grants differ from the reviewed set: ${builtins.toJSON actual}";
    }
  ];
in
{
  invariantChecks = {
    invariants-registry-security =
      invariants.mkInvariantCheck "registry-security" registrySecurityInvariants
        { };

    # CI ships `main-ci` (profiles.ci = true; skipHeavyPackages = true), not
    # the full `main` closure; pin the same invariants to it so the gated
    # build is what gets validated.
    invariants-main-ci = hostInvariantCheck "main-ci" "main" ciNixosConfigs.main-ci;

    # The installer ISO is not a registry host but exposes SSH on TCP/22 to
    # whatever network it boots on: it must stay key-only.
    invariants-installer =
      invariants.mkInvariantCheck "installer"
        [
          {
            name = "installer SSH is key-only";
            check =
              cfg:
              let
                s = cfg.services.openssh.settings;
              in
              mkResult (
                s.PermitRootLogin == "prohibit-password"
                && s.PasswordAuthentication == false
                && s.KbdInteractiveAuthentication == false
              ) "installer sshd must allow only key-based root login";
          }
        ]
        (lib.nixosSystem {
          system = pkgs.stdenv.hostPlatform.system;
          modules = [ ../hosts/installer/default.nix ];
        }).config;

    python-development-main = checkPythonFiles allNixosConfigs.main.config.home-manager.users.user;
    python-development-main-ci = checkPythonFiles ciNixosConfigs.main-ci.config.home-manager.users.user;

    observability-alerts-lint = observabilityAlertsLint;
    backup-retention-behaviour = backupRetentionBehaviour;
    observability-stack-fixture = observabilityStackFixture;
    observability-client-fixture = observabilityClientFixture;
    observability-dashboard-backend-assertion-fixture = observabilityDashboardBackendAssertionFixture;
    services-hardened-example-fixture = servicesHardenedExampleFixture;
    profiles-base-standalone-fixture = profilesBaseStandaloneFixture;
    mini-fleet-example-fixture = miniFleetExampleFixture;
  }
  // generatedInvariantChecks
  // generatedSopsBootstrapChecks;

  ciTestsFor = system: {
    homeserver-gcp-smoke = import ../tests/nixos/homeserver-gcp-smoke.nix {
      inherit nixpkgs system;
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
    profile-runtime-timezone = import ../tests/nixos/profile-runtime-timezone.nix {
      inherit nixpkgs system;
    };
    quiet-shell-smoke = import ../tests/nixos/quiet-shell-smoke.nix {
      inherit nixpkgs system;
    };
    desktop-session = import ../tests/nixos/desktop-session.nix {
      inherit nixpkgs system;
      inherit (inputs) home-manager;
    };
  };
}
