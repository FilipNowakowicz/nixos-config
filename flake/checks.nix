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

  invalidInitrdSecrets =
    cfg:
    let
      values = lib.attrValues cfg.boot.initrd.secrets;
      nonNull = lib.filter (v: v != null) values;
    in
    lib.filter (v: !lib.hasPrefix "/run/secrets/" v) nonNull;

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

  sshFail2banHardened = {
    name = "SSH hosts enforce hardened fail2ban";
    check =
      cfg:
      let
        violations = lib.filter (msg: msg != "") [
          (lib.optionalString (!cfg.services.fail2ban.enable) "services.fail2ban.enable must be true")
          (lib.optionalString (cfg.services.fail2ban.maxretry > 3) "services.fail2ban.maxretry must be <= 3")
          (lib.optionalString (
            cfg.services.fail2ban.bantime != "30m"
          ) "services.fail2ban.bantime must be \"30m\"")
          (lib.optionalString (
            !cfg.services.fail2ban."bantime-increment".enable
          ) "services.fail2ban.bantime-increment.enable must be true")
          (lib.optionalString (
            cfg.services.fail2ban."bantime-increment".maxtime == null
          ) "services.fail2ban.bantime-increment.maxtime must be set")
        ];
      in
      if !cfg.services.openssh.enable then
        mkResult true "services.openssh.enable is false"
      else
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
        ];
        violations = lib.filter (msg: msg != "") [
          (lib.optionalString (
            backup.repository != "b2:filipnowakowicz-gcp:"
          ) "services.restic.backups.b2.repository must target filipnowakowicz-gcp")
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
in
{
  invariantChecks = {
    invariants-main = invariants.mkInvariantCheck "main" (
      [
        {
          name = "has stateVersion";
          check = cfg: require (cfg.system.stateVersion != null) "system.stateVersion must be set";
        }
        {
          name = "no passwordless sudo";
          check =
            cfg: require cfg.security.sudo.wheelNeedsPassword "security.sudo.wheelNeedsPassword must be true";
        }
        {
          name = "initrd secrets point to sops-managed paths";
          check =
            cfg:
            let
              invalid = invalidInitrdSecrets cfg;
            in
            mkResult (
              invalid == [ ]
            ) "boot.initrd.secrets must point to /run/secrets/*, got: ${lib.concatStringsSep ", " invalid}";
        }
        nixpkgsRegistryPinnedToFlakeInput
        mainInteractiveShellUsesNixIndexAndComma
        sshFail2banHardened
        obsClientUsesCanonicalUsername
        mainSshIsTailnetOnly
        mainUsbguardIsDenyDefault
        mainLocalBackupProtectsCriticalPaths
      ]
      ++ registryAssertionsFor "main"
    ) allNixosConfigs.main.config;

    invariants-homeserver-gcp = invariants.mkInvariantCheck "homeserver-gcp" (
      [
        {
          name = "has stateVersion";
          check = cfg: require (cfg.system.stateVersion != null) "system.stateVersion must be set";
        }
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
          name = "nix trusted-users stay minimal";
          check =
            cfg:
            invariants.checkExpectedTrustedUsers (
              [ "root" ]
              ++ lib.optional (hostRegistry.homeserver-gcp ? deploy) hostRegistry.homeserver-gcp.deploy.sshUser
            ) cfg;
        }
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
        {
          name = "sops uses SSH host key for decryption";
          check =
            cfg:
            require (
              cfg.sops.age.sshKeyPaths != [ ]
            ) "sops.age.sshKeyPaths must contain at least one SSH host key path";
        }
        nixpkgsRegistryPinnedToFlakeInput
        sshFail2banHardened
        homeserverGcpB2BackupUsesCriticalPolicy
      ]
      ++ registryAssertionsFor "homeserver-gcp"
    ) ciNixosConfigs.homeserver-gcp.config;

    homeserver-gcp-sops-bootstrap =
      let
        secretsDir = ../hosts/homeserver-gcp/secrets;
        hasKey = builtins.pathExists (secretsDir + "/ssh_host_ed25519_key.enc");
        hasPub = builtins.pathExists (secretsDir + "/ssh_host_ed25519_key.pub.enc");
      in
      if hasKey && hasPub then
        pkgs.runCommand "homeserver-gcp-sops-bootstrap-check" { } "touch $out"
      else
        pkgs.runCommand "homeserver-gcp-sops-bootstrap-check" { } ''
          echo "homeserver-gcp sops bootstrap incomplete — missing pre-baked host key files:"
          ${lib.optionalString (!hasKey) ''echo "  hosts/homeserver-gcp/secrets/ssh_host_ed25519_key.enc"''}
          ${lib.optionalString (
            !hasPub
          ) ''echo "  hosts/homeserver-gcp/secrets/ssh_host_ed25519_key.pub.enc"''}
          exit 1
        '';
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
