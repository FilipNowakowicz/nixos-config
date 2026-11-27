# Invariants and checks that guard hosts/main alone, beside the config they
# read. flake/checks.nix layers `invariants` on the fleet baseline for
# `invariants-main` and `invariants-main-ci`, feeds `inventoryAssertions` to
# the inventory, and merges `checks` into the flake checks.
{
  lib,
  pkgs,
  invariants,
  nixosConfigurations,
  ...
}:
let
  inherit (invariants)
    formatList
    interfaceTCPExposureViolations
    mkResult
    require
    requirePaths
    ;

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

  mainSshIsTailnetOnly = {
    name = "main SSH stays tailnet-only";
    check =
      cfg:
      let
        violations =
          interfaceTCPExposureViolations {
            interface = "tailscale0";
            ports = [ 22 ];
          } cfg
          ++ lib.filter (msg: msg != "") [
            (lib.optionalString (!cfg.services.openssh.enable) "services.openssh.enable must be true")
            (lib.optionalString cfg.services.openssh.openFirewall "services.openssh.openFirewall must be false")
            (lib.optionalString (!cfg.services.tailscale.enable) "services.tailscale.enable must be true")
            (lib.optionalString (
              !cfg.services.tailscale.openFirewall
            ) "services.tailscale.openFirewall must be true")
          ];
      in
      mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
  };

  mainBluetoothDriverHasBootTrigger = {
    name = "blacklisted Bluetooth driver has an independent boot timer";
    check =
      cfg:
      let
        needsLoader =
          (cfg.hardware.bluetooth.enable or false)
          && lib.elem "btusb" (cfg.boot.blacklistedKernelModules or [ ]);
        timer = cfg.systemd.timers.bluetooth-load-btusb or { };
        loader = cfg.systemd.services.bluetooth-load-btusb or { };
        delay = timer.timerConfig.OnActiveSec or null;
        unit = timer.timerConfig.Unit or "bluetooth-load-btusb.service";
        violations = lib.filter (msg: msg != "") [
          (lib.optionalString (!(loader.enable or false)) "Bluetooth driver loader must be enabled")
          (lib.optionalString (!(timer.enable or false)) "Bluetooth driver boot timer must be enabled")
          (lib.optionalString (
            !(lib.elem "timers.target" (timer.wantedBy or [ ]))
          ) "Bluetooth driver timer must start from timers.target, independently of bluetooth.target")
          (lib.optionalString (
            delay == null || delay == ""
          ) "Bluetooth driver timer must have an OnActiveSec trigger")
          (lib.optionalString (
            unit != "bluetooth-load-btusb.service"
          ) "Bluetooth driver timer must activate bluetooth-load-btusb.service")
        ];
      in
      mkResult (!needsLoader || violations == [ ]) (
        if needsLoader then
          lib.concatStringsSep "; " violations
        else
          "Bluetooth does not need a blacklisted driver loader"
      );
  };

  mainUsbguardIsDenyDefault = {
    name = "main USBGuard stays deny-default";
    check =
      cfg:
      let
        rules = cfg.services.usbguard.rules or "";
        ruleLines = lib.filter (l: l != "" && !lib.hasPrefix "#" l) (
          map lib.trim (lib.splitString "\n" rules)
        );
        broadAllows = lib.filter (l: lib.hasPrefix "allow" l && !lib.hasPrefix "allow id " l) ruleLines;
        violations = lib.filter (msg: msg != "") [
          (lib.optionalString (!cfg.services.usbguard.enable) "services.usbguard.enable must be true")
          (lib.optionalString (
            !lib.hasInfix "allow id " rules
          ) "services.usbguard.rules must whitelist at least one device")
          (lib.optionalString (
            ruleLines == [ ] || lib.last ruleLines != "reject"
          ) "services.usbguard.rules must end with a default reject rule")
          (lib.optionalString (
            broadAllows != [ ]
          ) "services.usbguard.rules has allow rule(s) not pinned to a device id: ${formatList broadAllows}")
        ];
      in
      mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
  };

  mainLocalBackupProtectsCriticalPaths = {
    name = "main local backup covers critical operator data";
    check =
      cfg:
      let
        backup = cfg.services.restic.backups.local or { };
        inherit (cfg.users.users.${cfg.profiles.primaryUser}) home;
        expectedPaths = [
          "${home}/.ssh"
          "${home}/.gnupg"
          "${home}/nix"
        ];
        pathCheck = requirePaths (backup.paths or [ ]) expectedPaths;
        violations = lib.filter (msg: msg != "") [
          (lib.optionalString (
            !(lib.hasPrefix "/run/secrets/" (backup.passwordFile or ""))
          ) "services.restic.backups.local.passwordFile must come from /run/secrets/*")
          (lib.optionalString (
            !(backup.initialize or false)
          ) "services.restic.backups.local.initialize must be true")
          (lib.optionalString (
            (backup.timerConfig.OnCalendar or null) != "daily"
          ) "services.restic.backups.local.timerConfig.OnCalendar must be \"daily\"")
          (lib.optionalString (!pathCheck.passed) pathCheck.message)
        ];
      in
      mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
  };

  # Pre-sorted so the check can compare directly without sorting a constant on
  # every eval. Mirrors hosts/main/agent-maintenance.nix's agentMaintenanceCommands.
  mainExpectedAgentMaintenanceCommands = [
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

        commandPath = command: command.command or "";
        commandOptions = command: command.options or [ ];
        hasOnlyOptions = options: command: commandOptions command == options;
        sortedCommandPaths = rule: lib.sort builtins.lessThan (map commandPath (rule.commands or [ ]));
        hostIsAll = rule: (rule.host or "ALL") == "ALL";
        runAsIsAll = rule: (rule.runAs or "ALL:ALL") == "ALL:ALL";

        isSetenvAllRule =
          rule:
          hostIsAll rule
          && runAsIsAll rule
          &&
            (rule.commands or [ ]) == [
              {
                command = "ALL";
                options = [ "SETENV" ];
              }
            ];

        isDefaultRootSetenvRule =
          rule: isSetenvAllRule rule && (rule.users or [ ]) == [ "root" ] && (rule.groups or [ ]) == [ ];

        isDefaultWheelSetenvRule =
          rule: isSetenvAllRule rule && (rule.users or [ ]) == [ ] && (rule.groups or [ ]) == [ "wheel" ];

        isAgentMaintenanceRule =
          rule:
          hostIsAll rule
          && runAsIsAll rule
          && (rule.users or [ ]) == [ "user" ]
          && (rule.groups or [ ]) == [ ]
          && sortedCommandPaths rule == mainExpectedAgentMaintenanceCommands
          && lib.all (hasOnlyOptions [ "NOPASSWD" ]) (rule.commands or [ ]);

        # btrbk's NixOS module grants the btrbk user NOPASSWD btrfs/mkdir/readlink
        # twice: once via the stable /run/current-system/sw/bin wrapper (used over
        # ssh) and once via the package's own Nix store path (used locally). Store
        # paths carry a build-dependent hash, so match those by store-relative
        # shape (under /nix/store, ending in /bin/<name>) rather than full
        # equality.
        btrbkCommandNames = [
          "btrfs"
          "mkdir"
          "readlink"
        ];
        btrbkStablePaths = map (name: "/run/current-system/sw/bin/${name}") btrbkCommandNames;
        isBtrbkStoreCommandPath =
          path:
          lib.hasPrefix (builtins.storeDir + "/") path
          && lib.any (name: lib.hasSuffix "/bin/${name}" path) btrbkCommandNames;
        classifyBtrbkCommandPath =
          path:
          if lib.elem path btrbkStablePaths then
            "stable:${builtins.baseNameOf path}"
          else if isBtrbkStoreCommandPath path then
            "store:${builtins.baseNameOf path}"
          else
            "other:${path}";
        expectedBtrbkCommandClasses = lib.sort builtins.lessThan (
          map (name: "stable:${name}") btrbkCommandNames ++ map (name: "store:${name}") btrbkCommandNames
        );

        isBtrbkMaintenanceRule =
          rule:
          let
            commands = rule.commands or [ ];
          in
          hostIsAll rule
          && runAsIsAll rule
          && (rule.users or [ ]) == [ "btrbk" ]
          && (rule.groups or [ ]) == [ ]
          && lib.all (hasOnlyOptions [ "NOPASSWD" ]) commands
          &&
            lib.sort builtins.lessThan (map (c: classifyBtrbkCommandPath (commandPath c)) commands)
            == expectedBtrbkCommandClasses;

        isKnownRule =
          rule:
          isDefaultRootSetenvRule rule
          || isDefaultWheelSetenvRule rule
          || isAgentMaintenanceRule rule
          || isBtrbkMaintenanceRule rule;

        rootSetenvRules = lib.filter isDefaultRootSetenvRule extraRules;
        wheelSetenvRules = lib.filter isDefaultWheelSetenvRule extraRules;
        agentRules = lib.filter isAgentMaintenanceRule extraRules;
        btrbkRules = lib.filter isBtrbkMaintenanceRule extraRules;
        unexpectedRules = lib.filter (rule: !(isKnownRule rule)) extraRules;

        countViolation =
          label: rules:
          lib.optionalString (
            lib.length rules != 1
          ) "expected exactly 1 ${label}, got ${toString (lib.length rules)}";

        violations = lib.filter (msg: msg != "") [
          (countViolation "default root SETENV rule" rootSetenvRules)
          (countViolation "default wheel SETENV rule" wheelSetenvRules)
          (countViolation "agent maintenance allowlist rule" agentRules)
          (countViolation "btrbk maintenance allowlist rule" btrbkRules)
          (lib.optionalString (
            unexpectedRules != [ ]
          ) "main sudo extraRules contains ${toString (lib.length unexpectedRules)} unexpected rule(s)")
        ];
      in
      mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
  };

  mullvadTailscaleCoexistence = {
    name = "Mullvad and Tailscale coexistence assumptions hold";
    check =
      cfg:
      let
        mullvadEnabled = cfg.services.mullvad-vpn.enable or false;
        tailscaleEnabled = cfg.services.tailscale.enable or false;
        bothEnabled = mullvadEnabled && tailscaleEnabled;
        nftContent = cfg.networking.nftables.tables."tailscale-mullvad-compat".content or "";
        bypassService = cfg.systemd.services.tailscale-bypass-routing or null;
        tailscaledPostStart = cfg.systemd.services.tailscaled.postStart or "";
        mullvadPostStart = cfg.systemd.services.mullvad-daemon.postStart or "";
        mullvadLockdown = cfg.systemd.services.mullvad-lockdown or null;
        requiredUnits = [
          "tailscaled.service"
          "mullvad-daemon.service"
        ];
        missingAfter =
          if bypassService == null then
            requiredUnits
          else
            lib.filter (unit: !(builtins.elem unit (bypassService.after or [ ]))) requiredUnits;
        missingWants =
          if bypassService == null then
            requiredUnits
          else
            lib.filter (unit: !(builtins.elem unit (bypassService.wants or [ ]))) requiredUnits;
        violations = lib.filter (msg: msg != "") [
          (lib.optionalString (
            bothEnabled && (cfg.networking.firewall.checkReversePath or null) != "loose"
          ) ''networking.firewall.checkReversePath must be "loose" when Mullvad and Tailscale coexist'')
          (lib.optionalString (
            bothEnabled && !lib.hasInfix "priority filter - 1" nftContent
          ) "tailscale-mullvad-compat nftables chain must run before Mullvad's filter priority")
          (lib.optionalString (
            bothEnabled && !lib.hasInfix ''oifname "tailscale0"'' nftContent
          ) "tailscale-mullvad-compat nftables chain must target tailscale0")
          (lib.optionalString (
            bothEnabled && !lib.hasInfix "ct mark set 0x00000f41" nftContent
          ) "tailscale-mullvad-compat nftables chain must set Mullvad's conntrack bypass mark")
          (lib.optionalString (
            bothEnabled && !lib.hasInfix "meta mark set 0x6d6f6c65" nftContent
          ) "tailscale-mullvad-compat nftables chain must set Mullvad's policy-routing bypass mark")
          (lib.optionalString (
            bothEnabled && bypassService == null
          ) "systemd.services.tailscale-bypass-routing must exist")
          (lib.optionalString (
            bothEnabled
            && bypassService != null
            && !builtins.elem "multi-user.target" (bypassService.wantedBy or [ ])
          ) "tailscale-bypass-routing.service must be wanted by multi-user.target")
          (lib.optionalString (
            bothEnabled && missingAfter != [ ]
          ) "tailscale-bypass-routing.service missing after unit(s): ${formatList missingAfter}")
          (lib.optionalString (
            bothEnabled && missingWants != [ ]
          ) "tailscale-bypass-routing.service missing wanted unit(s): ${formatList missingWants}")
          (lib.optionalString (
            bothEnabled && tailscaledPostStart == ""
          ) "systemd.services.tailscaled.postStart must re-assert the bypass route")
          (lib.optionalString (
            bothEnabled && mullvadPostStart == ""
          ) "systemd.services.mullvad-daemon.postStart must re-assert the bypass route")
          (lib.optionalString (
            bothEnabled && mullvadLockdown == null
          ) "systemd.services.mullvad-lockdown must exist")
          # nixpkgs starts tailscaled after network-online.target, and Mullvad's
          # packaged unit orders itself before it, so Mullvad-after-tailscaled is
          # an ordering cycle; systemd broke it at boot by dropping tailscaled.
          # Rule order is repaired by the bypass script's reconnect instead.
          (lib.optionalString
            (
              bothEnabled
              && builtins.elem "tailscaled.service" (cfg.systemd.services.mullvad-daemon.after or [ ])
              && builtins.elem "network-online.target" (cfg.systemd.services.tailscaled.after or [ ])
            )
            "mullvad-daemon.service must not start after tailscaled.service (ordering cycle via network-online.target)"
          )
        ];
      in
      mkResult (!bothEnabled || violations == [ ]) (
        if !bothEnabled then
          "Mullvad and Tailscale are not both enabled"
        else if violations == [ ] then
          "Mullvad and Tailscale coexistence assumptions hold"
        else
          lib.concatStringsSep "; " violations
      );
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

  accessInvariants = [
    {
      name = "no passwordless sudo";
      check =
        cfg: require cfg.security.sudo.wheelNeedsPassword "security.sudo.wheelNeedsPassword must be true";
    }
    mainAgentMaintenanceSudoAllowlist
    mainSshIsTailnetOnly
    mainNoGloballyOpenPorts
    mainUsbguardIsDenyDefault
    mullvadTailscaleCoexistence
  ];

  experienceInvariants = [
    mainBluetoothDriverHasBootTrigger
    mainInteractiveShellUsesNixIndexAndComma
    invariants.obsClientUsesCanonicalUsername
  ];

  backupInvariants = [
    mainLocalBackupProtectsCriticalPaths
    invariants.persistentNetworkTimersSurviveResume
    mainBackupPathsArePersisted
    mainBtrbkPolicyMatchesLocalSnapshotIntent
  ];

  hmUserOf = host: host.config.home-manager.users.${host.config.profiles.primaryUser};
  checkPythonFiles = import ../../home/profiles/python-development-check.nix { inherit lib pkgs; };

  # Run mainBackupPathsArePersisted against main's real config and against injected
  # faults it must reject: a tmpfs shadowing a persistent parent, at the
  # backed-up path and one level up, and a backup path left on the
  # rolled-back root.
  mainBackupPersistenceCases =
    let
      cfg = nixosConfigurations.main.config;
      inherit (cfg.users.users.${cfg.profiles.primaryUser}) home;
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
          config = withMount "${home}/.ssh";
          expected = false;
        };
        "tmpfs between /home and a backed-up path" = {
          config = withMount home;
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
      inherit (nixosConfigurations) main;
      mkProbe = import ./restic-wait-repo.nix { inherit (main) pkgs; };
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

  # Back up a marker tree with main's effective paths and excludes, restore it,
  # and require each marker to be present or absent. This catches an exclude
  # that swallows a listed path, which a paths-only invariant cannot see.
  # Paths are rebased under ./root; listed paths with no marker are skipped.
  mainBackupCoverage =
    let
      backup = nixosConfigurations.main.config.services.restic.backups.local;
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
in
{
  # Exposed for tests/lib/invariants.nix.
  inherit
    mainAgentMaintenanceSudoAllowlist
    mainBluetoothDriverHasBootTrigger
    mainExpectedAgentMaintenanceCommands
    mullvadTailscaleCoexistence
    ;

  invariants = accessInvariants ++ experienceInvariants ++ backupInvariants;

  # The subset reported per host in the generated inventory.
  inventoryAssertions = [
    mainSshIsTailnetOnly
    mainUsbguardIsDenyDefault
    mainLocalBackupProtectsCriticalPaths
  ];

  checks = {
    python-development-main = checkPythonFiles (hmUserOf nixosConfigurations.main);
    python-development-main-ci = checkPythonFiles (hmUserOf nixosConfigurations.main-ci);
    main-backup-coverage = mainBackupCoverage;
    main-backup-persistence-cases = mainBackupPersistenceCases;
    restic-wait-repo-behaviour = resticWaitRepoBehaviour;
  };
}
