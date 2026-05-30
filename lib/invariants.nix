{ lib, pkgs }:
let
  hasResticBackup =
    backupName: cfg:
    builtins.hasAttr backupName cfg.services.restic.backups
    && (
      let
        backup = cfg.services.restic.backups.${backupName};
      in
      (backup.paths or [ ]) != [ ]
      && (
        (backup ? repository && backup.repository != null)
        || (backup ? repositoryFile && backup.repositoryFile != null)
      )
    );
in
rec {
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

  formatList = values: lib.concatStringsSep ", " values;

  formatIntList = values: formatList (map builtins.toString values);

  interfaceAllowedTCPPorts =
    cfg: interface:
    let
      interfaces = cfg.networking.firewall.interfaces or { };
    in
    if builtins.hasAttr interface interfaces then
      interfaces.${interface}.allowedTCPPorts or [ ]
    else
      [ ];

  interfaceTCPExposureViolations =
    {
      interface,
      ports,
    }:
    cfg:
    let
      globalPorts = cfg.networking.firewall.allowedTCPPorts or [ ];
      interfaces = cfg.networking.firewall.interfaces or { };
      targetPorts = interfaceAllowedTCPPorts cfg interface;
      globallyOpen = lib.filter (port: builtins.elem port globalPorts) ports;
      missingOnTarget = lib.filter (port: !(builtins.elem port targetPorts)) ports;
      exposedElsewhere = lib.filterAttrs (
        name: value:
        name != interface && lib.any (port: builtins.elem port (value.allowedTCPPorts or [ ])) ports
      ) interfaces;
      elsewhereMessages = lib.mapAttrsToList (
        name: value:
        let
          offending = lib.filter (port: builtins.elem port (value.allowedTCPPorts or [ ])) ports;
        in
        "${name} (${formatIntList offending})"
      ) exposedElsewhere;
    in
    lib.filter (msg: msg != "") [
      (lib.optionalString (
        globallyOpen != [ ]
      ) "ports must not be globally open: ${formatIntList globallyOpen}")
      (lib.optionalString (missingOnTarget != [ ])
        "networking.firewall.interfaces.${interface}.allowedTCPPorts must include: ${formatIntList missingOnTarget}"
      )
      (lib.optionalString (
        elsewhereMessages != [ ]
      ) "ports must not be exposed on non-${interface} interfaces: ${formatList elsewhereMessages}")
    ];

  checkExpectedTrustedUsers =
    expectedUsers: cfg:
    let
      actualUsers = cfg.nix.settings.trusted-users or [ ];
      missingUsers = lib.filter (user: !(builtins.elem user actualUsers)) expectedUsers;
      unexpectedUsers = lib.filter (user: !(builtins.elem user expectedUsers)) actualUsers;
      violations = lib.filter (msg: msg != "") [
        (lib.optionalString (missingUsers != [ ]) "missing trusted users: ${formatList missingUsers}")
        (lib.optionalString (
          unexpectedUsers != [ ]
        ) "unexpected trusted users: ${formatList unexpectedUsers}")
      ];
    in
    {
      passed = violations == [ ];
      message =
        if violations == [ ] then
          "trusted users match expected set"
        else
          lib.concatStringsSep "; " violations;
    };

  checkHardenedFail2ban =
    cfg:
    let
      fail2ban = cfg.services.fail2ban or { };
      bantimeIncrement = fail2ban."bantime-increment" or { };
      violations = lib.filter (msg: msg != "") [
        (lib.optionalString (!(fail2ban.enable or false)) "services.fail2ban.enable must be true")
        (lib.optionalString ((fail2ban.maxretry or 0) > 3) "services.fail2ban.maxretry must be <= 3")
        (lib.optionalString (
          (fail2ban.bantime or null) != "30m"
        ) ''services.fail2ban.bantime must be "30m"'')
        (lib.optionalString (
          !(bantimeIncrement.enable or false)
        ) "services.fail2ban.bantime-increment.enable must be true")
        (lib.optionalString (
          (bantimeIncrement.maxtime or null) == null
        ) "services.fail2ban.bantime-increment.maxtime must be set")
      ];
    in
    {
      passed = violations == [ ];
      message =
        if violations == [ ] then "fail2ban is hardened" else lib.concatStringsSep "; " violations;
    };

  hasStateVersion = {
    name = "has stateVersion";
    check = cfg: require (cfg.system.stateVersion != null) "system.stateVersion must be set";
  };

  sshHostsEnforceHardenedFail2ban = {
    name = "SSH hosts enforce hardened fail2ban";
    check = cfg: if !cfg.services.openssh.enable then true else checkHardenedFail2ban cfg;
  };

  obsClientUsesCanonicalUsername = {
    name = "observability client uses canonical ingest username";
    check =
      cfg:
      let
        clientEnabled = cfg.profiles.observability-client.enable or false;
        usernameRaw = lib.attrByPath [
          "profiles"
          "observability"
          "ingestAuth"
          "username"
        ] "telemetry" cfg;
        username = if usernameRaw == null then "telemetry" else usernameRaw;
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
        backup = cfg.services.restic.backups.local or { };
        expectedPaths = [
          "/home/user/.ssh"
          "/home/user/.gnupg"
          "/home/user/nix"
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

  deployTargetAccessAssertions = [
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

  homeserverSshAndHttpsNotGloballyOpen = {
    name = "SSH and HTTPS are not globally open";
    check = cfg: checkNoGlobalTCPPorts [ 22 443 ] cfg;
  };

  homeserverSshAndHttpsTailscaleOnly = {
    name = "SSH and HTTPS stay Tailscale-only";
    check =
      cfg:
      checkTCPPortsRestrictedToInterface {
        interface = "tailscale0";
        ports = [
          22
          443
        ];
      } cfg;
  };

  macSshNotGloballyOpen = {
    name = "SSH is not globally open";
    check = cfg: checkNoGlobalTCPPorts [ 22 ] cfg;
  };

  macSshTailscaleOnly = {
    name = "SSH stays Tailscale-only";
    check =
      cfg:
      checkTCPPortsRestrictedToInterface {
        interface = "tailscale0";
        ports = [ 22 ];
      } cfg;
  };

  checkNoGlobalTCPPorts =
    ports: cfg:
    let
      globalPorts = cfg.networking.firewall.allowedTCPPorts or [ ];
      globallyOpen = lib.filter (port: builtins.elem port globalPorts) ports;
    in
    {
      passed = globallyOpen == [ ];
      message =
        if globallyOpen == [ ] then
          "ports are not globally open"
        else
          "ports must not be globally open: ${formatIntList globallyOpen}";
    };

  checkTCPPortsRestrictedToInterface =
    {
      interface,
      ports,
    }:
    cfg:
    let
      violations = interfaceTCPExposureViolations { inherit interface ports; } cfg;
    in
    {
      passed = violations == [ ];
      message =
        if violations == [ ] then
          "ports are restricted to ${interface}"
        else
          lib.concatStringsSep "; " violations;
    };

  normalizeCheckResult =
    assertionName: result:
    if builtins.isBool result then
      {
        passed = result;
        message = assertionName;
      }
    else if builtins.isAttrs result && result ? passed then
      {
        inherit (result) passed;
        message = result.message or assertionName;
      }
    else
      throw "Invariant '${assertionName}' must return a bool or { passed; message; }";

  evaluateAssertions =
    assertions: config:
    map (
      a:
      let
        normalized = normalizeCheckResult a.name (a.check config);
      in
      {
        inherit (a) name;
        inherit (normalized) passed message;
      }
    ) assertions;

  mkInvariantCheck =
    hostName: assertions: config:
    let
      results = evaluateAssertions assertions config;
      failures = lib.filter (r: !r.passed) results;
      errorMsg = lib.concatMapStringsSep "\n" (
        f: if f.message == "" || f.message == f.name then "  ✗ ${f.name}" else "  ✗ ${f.name}: ${f.message}"
      ) failures;
    in
    if failures == [ ] then
      pkgs.runCommand "invariant-check-${hostName}-pass" { } "touch $out"
    else
      pkgs.runCommand "invariant-check-${hostName}-fail" { } ''
        echo "Invariant check failed for '${hostName}':"
        echo "${errorMsg}"
        exit 1
      '';

  mkRegistryAssertions =
    hostName: hostMeta:
    [
      {
        name = "networking.hostName matches registry key";
        check = cfg: cfg.networking.hostName == hostName;
      }
    ]
    ++ lib.optionals (hostMeta ? deploy) [
      {
        name = "deployable hosts enable OpenSSH";
        check = cfg: cfg.services.openssh.enable;
      }
    ]
    ++ lib.optionals (hostMeta ? backup) [
      {
        name = "backup metadata configures Restic backup target";
        check = hasResticBackup (hostMeta.backup.name or "local");
      }
    ]
    ++ lib.optionals ((hostMeta ? tailscale) || (hostMeta ? tailnetFQDN)) [
      {
        name = "tailnet metadata enables Tailscale";
        check = cfg: cfg.services.tailscale.enable;
      }
    ];
}
