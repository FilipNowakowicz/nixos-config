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
  mkResult = passed: message: {
    inherit passed message;
  };

  require = condition: message: mkResult condition message;

  requirePaths =
    actual: expected:
    let
      missing = lib.filter (path: !(builtins.elem path actual)) expected;
    in
    mkResult (missing == [ ]) "missing expected path(s): ${lib.concatStringsSep ", " missing}";

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

  obsClientUsesCanonicalUsername = {
    name = "observability client uses canonical ingest username";
    check =
      cfg:
      let
        clientEnabled = cfg.profiles.observability-client.enable;
        inherit (cfg.profiles.observability.ingestAuth) username;
      in
      require (
        !clientEnabled || username == "telemetry"
      ) "profiles.observability.ingestAuth.username must be 'telemetry', got '${username}'";
  };

  mainSshIsTailnetOnly = {
    name = "main SSH stays tailnet-only";
    check =
      cfg:
      let
        violations = lib.filter (msg: msg != "") [
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

  mainUsbguardIsDenyDefault = {
    name = "main USBGuard stays deny-default";
    check =
      cfg:
      let
        rules = cfg.services.usbguard.rules or "";
        violations = lib.filter (msg: msg != "") [
          (lib.optionalString (!cfg.services.usbguard.enable) "services.usbguard.enable must be true")
          (lib.optionalString (
            !lib.hasInfix "allow id " rules
          ) "services.usbguard.rules must whitelist at least one device")
          (lib.optionalString (
            !lib.hasInfix "reject" rules
          ) "services.usbguard.rules must include a default reject rule")
        ];
      in
      mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
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

        # /home, /nix, and /persist are independent btrfs subvolumes that are
        # not rolled back. Anything under them already survives reboot.
        persistentRoots = [
          "/home/"
          "/nix/"
          "/persist/"
        ];

        isPersistent =
          path:
          lib.any (root: lib.hasPrefix root path) persistentRoots
          || lib.elem path persistedDirs
          || lib.elem path persistedFiles
          || lib.any (d: lib.hasPrefix (d + "/") path) persistedDirs;

        offenders = lib.filter (p: !(isPersistent p)) (cfg.services.restic.backups.local.paths or [ ]);
      in
      mkResult (offenders == [ ])
        "backup path(s) not persisted (would be wiped on rollback boot): ${lib.concatStringsSep ", " offenders}";
  };

  mainLocalBackupProtectsCriticalPaths = {
    name = "main local backup covers critical operator data";
    check =
      cfg:
      let
        backup = cfg.services.restic.backups.local;
        expectedPaths = [
          "/home/user/.ssh"
          "/home/user/.gnupg"
          "/home/user/nix"
        ];
        pathCheck = requirePaths backup.paths expectedPaths;
        violations = lib.filter (msg: msg != "") [
          (lib.optionalString (
            !(lib.hasPrefix "/run/secrets/" (backup.passwordFile or ""))
          ) "services.restic.backups.local.passwordFile must come from /run/secrets/*")
          (lib.optionalString (!backup.initialize) "services.restic.backups.local.initialize must be true")
          (lib.optionalString (
            (backup.timerConfig.OnCalendar or null) != "daily"
          ) "services.restic.backups.local.timerConfig.OnCalendar must be \"daily\"")
          (lib.optionalString (!pathCheck.passed) pathCheck.message)
        ];
      in
      mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
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
          "/var/lib/private/AdGuardHome"
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
    {
      name = "has stateVersion";
      check = cfg: require (cfg.system.stateVersion != null) "system.stateVersion must be set";
    }
    nixpkgsRegistryPinnedToFlakeInput
  ];

  mainAccessInvariants = [
    {
      name = "no passwordless sudo";
      check =
        cfg: require cfg.security.sudo.wheelNeedsPassword "security.sudo.wheelNeedsPassword must be true";
    }
    mainSshIsTailnetOnly
    mainUsbguardIsDenyDefault
  ];

  mainExperienceInvariants = [
    mainInteractiveShellUsesNixIndexAndComma
    obsClientUsesCanonicalUsername
  ];

  mainBackupInvariants = [
    mainLocalBackupProtectsCriticalPaths
    mainBackupPathsArePersisted
    mainBtrbkPolicyMatchesLocalSnapshotIntent
  ];

  # Invariants shared by all deploy-rs targets (passwordless wheel, SSH tailnet-only).
  deployTargetAccessInvariants = [
    {
      name = "passwordless sudo enabled";
      check =
        cfg:
        require (!cfg.security.sudo.wheelNeedsPassword)
          "security.sudo.wheelNeedsPassword must be false (deploy-rs needs passwordless sudo; access is SSH-key-only over Tailscale)";
    }
    {
      name = "firewall enabled";
      check = cfg: require cfg.networking.firewall.enable "networking.firewall.enable must be true";
    }
    {
      name = "sops uses SSH host key for decryption";
      check =
        cfg:
        require (
          cfg.sops.age.sshKeyPaths != [ ]
        ) "sops.age.sshKeyPaths must contain at least one SSH host key path";
    }
  ];

  homeserverAccessInvariants = deployTargetAccessInvariants ++ [
    {
      name = "SSH and HTTPS are not globally open";
      check = cfg: invariants.checkNoGlobalTCPPorts [ 22 443 ] cfg;
    }
    {
      name = "SSH and HTTPS stay Tailscale-only";
      check =
        cfg:
        invariants.checkTCPPortsRestrictedToInterface {
          interface = "tailscale0";
          ports = [
            22
            443
          ];
        } cfg;
    }
  ];

  homeserverBackupInvariants = [
    homeserverGcpB2BackupUsesCriticalPolicy
  ];

  # mac is a deploy-rs target like homeserver-gcp (passwordless wheel, SSH tailnet-only)
  # but does not publish HTTPS, so only SSH ports are checked.
  macAccessInvariants = deployTargetAccessInvariants ++ [
    {
      name = "SSH is not globally open";
      check = cfg: invariants.checkNoGlobalTCPPorts [ 22 ] cfg;
    }
    {
      name = "SSH stays Tailscale-only";
      check =
        cfg:
        invariants.checkTCPPortsRestrictedToInterface {
          interface = "tailscale0";
          ports = [ 22 ];
        } cfg;
    }
  ];

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
in
{
  invariantChecks = {
    invariants-main = invariants.mkInvariantCheck "main" (
      commonSystemInvariants
      ++ mainAccessInvariants
      ++ mainExperienceInvariants
      ++ mainBackupInvariants
      ++ registryAssertionsFor "main"
    ) allNixosConfigs.main.config;

    invariants-homeserver-gcp = invariants.mkInvariantCheck "homeserver-gcp" (
      commonSystemInvariants
      ++ homeserverAccessInvariants
      ++ homeserverBackupInvariants
      ++ registryAssertionsFor "homeserver-gcp"
    ) ciNixosConfigs.homeserver-gcp.config;

    invariants-mac = invariants.mkInvariantCheck "mac" (
      commonSystemInvariants ++ macAccessInvariants ++ registryAssertionsFor "mac"
    ) allNixosConfigs.mac.config;

    homeserver-gcp-sops-bootstrap = mkSopsBootstrapCheck "homeserver-gcp" ../hosts/homeserver-gcp/secrets;

    mac-sops-bootstrap = mkSopsBootstrapCheck "mac" ../hosts/mac/secrets;
  };

  cveReportPackagesFor =
    system:
    let
      targetPkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      targetCveChecks = import ../lib/cve-checks.nix { pkgs = targetPkgs; };
    in
    {
      main = targetCveChecks.mkCveCheck "main" allNixosConfigs.main.config.system.build.toplevel;
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
