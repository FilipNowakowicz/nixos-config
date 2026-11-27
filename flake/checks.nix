{
  lib,
  pkgs,
  nixpkgs,
  inputs,
  hostRegistry,
  allNixosConfigs,
  ciNixosConfigs,
  invariants,
  self,
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

  hmUserOf = host: host.config.home-manager.users.${host.config.profiles.primaryUser};
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
        # Every mount that can own a path: real filesystems, and impermanence
        # binds from /persist. Only the deepest owner decides, so a tmpfs
        # mounted below a persistent /home shadows it and fails here.
        owners =
          lib.mapAttrsToList (mountPoint: fs: {
            path = mountPoint;
            persistent = (fs.fsType or "") == "btrfs" && subvolFor fs != null && subvolFor fs != "/@root";
          }) cfg.fileSystems
          ++ map (path: {
            inherit path;
            persistent = true;
          }) (persistedDirs ++ persistedFiles);
        isUnderRoot = root: path: path == root || root == "/" || lib.hasPrefix "${root}/" path;

        isPersistent =
          path:
          let
            matching = lib.filter (o: isUnderRoot o.path path) owners;
            depth = o: lib.stringLength o.path;
            deepest = lib.foldl' lib.max 0 (map depth matching);
          in
          # At equal depth an impermanence bind wins over the mount it covers.
          lib.any (o: o.persistent) (lib.filter (o: depth o == deepest) matching);

        offenders = lib.filter (p: !(isPersistent p)) (cfg.services.restic.backups.local.paths or [ ]);
      in
      mkResult (offenders == [ ])
        "backup path(s) not persisted (would be wiped on rollback boot): ${lib.concatStringsSep ", " offenders}";
  };

  # Run the invariant above against main's real config and against injected
  # faults it must reject: a tmpfs shadowing a persistent parent, at the
  # backed-up path and one level up, and a backup path left on the
  # rolled-back root.
  mainBackupPersistenceCases =
    let
      cfg = allNixosConfigs.main.config;
      passes = c: (mainBackupPathsArePersisted.check c).passed;
      withMount =
        mountPoint:
        cfg
        // {
          fileSystems = cfg.fileSystems // {
            ${mountPoint} = {
              fsType = "tmpfs";
              options = [ "mode=0700" ];
            };
          };
        };
      withPath =
        path:
        lib.recursiveUpdate cfg {
          services.restic.backups.local.paths = cfg.services.restic.backups.local.paths ++ [ path ];
        };
      cases = {
        "deployed config" = {
          config = cfg;
          expected = true;
        };
        "tmpfs on a backed-up path" = {
          config = withMount "/home/user/.ssh";
          expected = false;
        };
        "tmpfs between /home and a backed-up path" = {
          config = withMount "/home/user";
          expected = false;
        };
        "backup path on the rolled-back root" = {
          config = withPath "/var/lib/upower";
          expected = false;
        };
      };
      wrong = lib.filterAttrs (_: c: passes c.config != c.expected) cases;
    in
    pkgs.runCommand "main-backup-persistence-cases" { } (
      if wrong == { } then
        "touch $out"
      else
        "echo 'persistence invariant misjudged: ${lib.concatStringsSep ", " (builtins.attrNames wrong)}' >&2; exit 1"
    );

  # Exercise main's restic pre-start probe. A fake restic replays exit codes
  # from $PLAN (one per call, logging each call); the real one pins the exit
  # code restic gives for a missing repository. Each deployed unit's first
  # ExecStartPre must be this same generated script, so a renamed no-op
  # cannot stand in for it.
  resticWaitRepoBehaviour =
    let
      inherit (allNixosConfigs) main;
      mkProbe = import ../hosts/main/restic-wait-repo.nix { inherit (main) pkgs; };
      fakeRestic = pkgs.writeShellScriptBin "restic" ''
        echo call >> "$CALLS"
        code=$(${pkgs.coreutils}/bin/head -n1 "$PLAN")
        ${pkgs.gnused}/bin/sed -i 1d "$PLAN"
        echo "fake restic exit $code" >&2
        exit "''${code:-1}"
      '';
      probe =
        restic:
        mkProbe {
          unit = "probe-test";
          repositoryFile = "repo-file";
          inherit restic;
          attempts = 4;
          interval = 0;
        };
      fake = probe fakeRestic;
      real = probe pkgs.restic;
      deployedFirst =
        unit: builtins.head (lib.toList main.config.systemd.services.${unit}.serviceConfig.ExecStartPre);
      expectedFor =
        unit:
        toString (mkProbe {
          inherit unit;
          repositoryFile = main.config.sops.secrets.restic_repository.path;
        });
      misplaced = lib.filter (unit: toString (deployedFirst unit) != expectedFor unit) [
        "restic-backups-local"
        "restic-check-local"
      ];
    in
    assert lib.assertMsg (
      misplaced == [ ]
    ) "first ExecStartPre is not the tested wait-repo probe: ${lib.concatStringsSep ", " misplaced}";
    pkgs.runCommand "restic-wait-repo-behaviour" { nativeBuildInputs = [ pkgs.restic ]; } ''
      export HOME=$PWD CALLS=$PWD/calls PLAN=$PWD/plan RESTIC_PASSWORD=fixture
      run() { # name, plan, expected status, expected calls, stderr pattern
        printf '%s\n' $2 > plan; : > calls
        status=0; ${fake} 2> err || status=$?
        [ "$status" = "$3" ] && [ "$(wc -l < calls)" = "$4" ] && { [ -z "$5" ] || grep -q "$5" err; } \
          || { echo "FAIL $1: status=$status calls=$(wc -l < calls)" >&2; cat err >&2; exit 1; }
      }
      run "recovers when connectivity returns" "1 1 0" 0 3 ""
      run "gives up after every attempt" "1 1 1 1" 1 4 "unreachable after 4 attempts; last error: fake restic exit 1"
      run "missing repository fails at once" "10" 1 1 "does not exist"
      run "wrong password fails at once" "12" 1 1 "wrong repository password"

      echo "$PWD/missing" > repo-file
      status=0; ${real} 2> err || status=$?
      [ "$status" = 1 ] && grep -q "does not exist" err \
        || { echo "FAIL real restic, missing repo: status=$status" >&2; cat err >&2; exit 1; }
      restic init -q -r "$PWD/missing"
      ${real} || { echo "FAIL real restic, existing repo" >&2; exit 1; }
      touch $out
    '';

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

  # Fleet checks that evaluate this flake's own outputs; see tests/flake/.
  flakeTestArgs = {
    inherit
      lib
      pkgs
      inputs
      self
      ;
  };
  miniFleet = import ../tests/flake/mini-fleet.nix flakeTestArgs;
  flakeTests = map (file: (import file flakeTestArgs).checks) [
    ../tests/flake/observability.nix
    ../tests/flake/backup-retention.nix
    ../tests/flake/public-modules.nix
  ];

  # Back up a marker tree with main's effective paths and excludes, restore it,
  # and require each marker to be present or absent. This catches an exclude
  # that swallows a listed path, which a paths-only invariant cannot see.
  # Paths are rebased under ./root; listed paths with no marker are skipped.
  mainBackupCoverage =
    let
      backup = allNixosConfigs.main.config.services.restic.backups.local;
      ankiLocal = "home/user/academic/anki-generator/local";
      kept = [
        "home/user/.ssh/marker"
        "home/user/nix/marker"
        "home/user/.local/share/Anki2/marker"
        "home/user/trading/secrets/marker"
        "home/user/trading/data/s004/marker"
        "home/user/trading/data/s004-effort/marker"
        "home/user/trading/data/astra/marker"
        "${ankiLocal}/workspace/maths-setup.json"
        "${ankiLocal}/paths.json"
        "${ankiLocal}/anki-courses.json"
        "${ankiLocal}/restic-snapshot/state.sqlite3"
      ];
      dropped = [
        "home/user/trading/data/betfair/marker"
        "home/user/trading/.venv/marker"
        "home/user/academic/materials/library/marker"
        "${ankiLocal}/workspace/backups/marker"
        "${ankiLocal}/workspace/state.sqlite3"
        "${ankiLocal}/workspace/state.sqlite3-journal"
        "${ankiLocal}/verification/marker"
        "home/user/.config/gcloud/credentials.db"
      ];
    in
    pkgs.runCommand "main-backup-coverage" { nativeBuildInputs = [ pkgs.restic ]; } ''
      export RESTIC_PASSWORD=fixture HOME=$PWD
      for m in ${lib.escapeShellArgs (kept ++ dropped)}; do
        mkdir -p "root/$(dirname "$m")"
        echo "$m" > "root/$m"
      done
      sources=()
      for p in ${lib.escapeShellArgs backup.paths}; do
        [ -e "root$p" ] && sources+=("root$p")
      done
      excludes=()
      for e in ${lib.escapeShellArgs backup.exclude}; do
        case "$e" in /*) e="$PWD/root$e" ;; esac
        excludes+=(--exclude "$e")
      done
      restic init -r repo -q
      restic backup -r repo -q "''${excludes[@]}" "''${sources[@]}"
      restic restore -r repo -q latest --target out
      fail=0
      for m in ${lib.escapeShellArgs kept}; do
        [ -e "out/root/$m" ] || { echo "not restored: /$m" >&2; fail=1; }
      done
      for m in ${lib.escapeShellArgs dropped}; do
        [ ! -e "out/root/$m" ] || { echo "restored but should be excluded: /$m" >&2; fail=1; }
      done
      [ "$fail" = 0 ]
      touch $out
    '';

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
    "gcp-builder" = onDemandAccessInvariants ++ [ invariants.workerJobsUserUnprivileged ];
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
              "workstation->workstation:22"
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
  # Generated docs samples, exposed as `legacyPackages.<system>.samples.*`.
  inherit (miniFleet) samples;

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

    python-development-main = checkPythonFiles (hmUserOf allNixosConfigs.main);
    python-development-main-ci = checkPythonFiles (hmUserOf ciNixosConfigs.main-ci);

    main-backup-coverage = mainBackupCoverage;
    main-backup-persistence-cases = mainBackupPersistenceCases;
    restic-wait-repo-behaviour = resticWaitRepoBehaviour;
  }
  // lib.mergeAttrsList flakeTests
  // miniFleet.checks
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
