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
    mkResult (missing == [ ]) (
      if missing == [ ] then
        "all required paths present"
      else
        "missing expected path(s): ${lib.concatStringsSep ", " missing}"
    );

  formatList = values: lib.concatStringsSep ", " values;

  formatIntList = values: formatList (map builtins.toString values);

  uniqueSorted = values: lib.sort builtins.lessThan (lib.unique values);

  activeHostNames =
    hostRegistry:
    uniqueSorted (
      lib.attrNames (lib.filterAttrs (_: hostMeta: (hostMeta.status or null) == "active") hostRegistry)
    );

  sopsHostNamesFromYaml =
    yaml:
    let
      lines = lib.splitString "\n" yaml;
      hostRuleForLine =
        line:
        let
          match = builtins.match ".*path_regex: hosts/([^/]+)/secrets/.*" line;
        in
        if match == null then [ ] else match;
      hostKeyForLine =
        line:
        let
          match = builtins.match ".*&([A-Za-z0-9_-]+)_host .*" line;
        in
        if match == null then [ ] else map (lib.replaceStrings [ "_" ] [ "-" ]) match;
    in
    {
      rules = uniqueSorted (lib.concatMap hostRuleForLine lines);
      keys = uniqueSorted (lib.concatMap hostKeyForLine lines);
    };

  checkSopsRecipientParity =
    hostRegistry: sopsYaml:
    let
      expectedHosts = activeHostNames hostRegistry;
      sopsHosts = sopsHostNamesFromYaml sopsYaml;
      missingRules = lib.filter (host: !(builtins.elem host sopsHosts.rules)) expectedHosts;
      staleRules = lib.filter (host: !(builtins.elem host expectedHosts)) sopsHosts.rules;
      missingKeys = lib.filter (host: !(builtins.elem host sopsHosts.keys)) expectedHosts;
      staleKeys = lib.filter (host: !(builtins.elem host expectedHosts)) sopsHosts.keys;
      violations = lib.filter (msg: msg != "") [
        (lib.optionalString (
          missingRules != [ ]
        ) ".sops.yaml missing host secret rule(s): ${formatList missingRules}")
        (lib.optionalString (
          staleRules != [ ]
        ) ".sops.yaml has stale host secret rule(s): ${formatList staleRules}")
        (lib.optionalString (
          missingKeys != [ ]
        ) ".sops.yaml missing host recipient key(s): ${formatList missingKeys}")
        (lib.optionalString (
          staleKeys != [ ]
        ) ".sops.yaml has stale host recipient key(s): ${formatList staleKeys}")
      ];
    in
    mkResult (violations == [ ]) (
      if violations == [ ] then
        "SOPS host recipients match active host registry"
      else
        lib.concatStringsSep "; " violations
    );

  checkDeployTargetsHaveTailnetAddresses =
    hostRegistry:
    let
      offenders = lib.attrNames (
        lib.filterAttrs (
          _: hostMeta: (hostMeta ? deploy) && !(hostMeta ? tailnetFQDN || hostMeta ? tailscale)
        ) hostRegistry
      );
    in
    mkResult (offenders == [ ]) (
      if offenders == [ ] then
        "deploy targets have tailnet metadata"
      else
        "deploy target(s) missing tailnetFQDN or tailscale metadata: ${formatList offenders}"
    );

  collectDiskoMountpoints =
    value:
    if builtins.isAttrs value then
      let
        here = lib.optional (builtins.isString (value.mountpoint or null)) value.mountpoint;
        childNames = lib.filter (name: !(lib.hasPrefix "_" name)) (builtins.attrNames value);
      in
      here ++ lib.concatMap (name: collectDiskoMountpoints value.${name}) childNames
    else
      [ ];

  checkImpermanentHostHasDiskoConfig =
    cfg:
    let
      persistence = cfg.environment.persistence or { };
      persistenceRoots = builtins.attrNames persistence;
      activeRoots = lib.filter (
        root:
        let
          rootCfg = persistence.${root};
        in
        (rootCfg.directories or [ ]) != [ ] || (rootCfg.files or [ ]) != [ ]
      ) persistenceRoots;
      diskoMountpoints = uniqueSorted (collectDiskoMountpoints (cfg.disko.devices or { }));
      missingRoots = lib.filter (root: !(builtins.elem root diskoMountpoints)) activeRoots;
    in
    mkResult (missingRoots == [ ]) (
      if missingRoots == [ ] then
        "impermanent host persistence roots have matching disko mountpoints"
      else
        "environment.persistence root(s) missing matching disko mountpoint: ${formatList missingRoots}"
    );

  checkAnonymousSpecialisationPersistence =
    cfg:
    let
      anonymousCfg = cfg.specialisation.anonymous.configuration or null;
      persistence =
        if anonymousCfg == null then { } else anonymousCfg.environment.persistence."/persist" or { };
      allowedDirectories = [
        "/var/lib/nixos"
        "/var/lib/systemd/backlight"
        "/var/lib/systemd/rfkill"
      ];
      allowedFiles = [
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
      ];
      normalize = entry: key: if builtins.isAttrs entry then entry.${key} else entry;
      directories = map (d: normalize d "directory") (persistence.directories or [ ]);
      files = map (f: normalize f "file") (persistence.files or [ ]);
      unexpectedDirectories = lib.filter (dir: !(builtins.elem dir allowedDirectories)) directories;
      unexpectedFiles = lib.filter (file: !(builtins.elem file allowedFiles)) files;
      missingDirectoryForces = lib.filter (dir: !(builtins.elem dir directories)) allowedDirectories;
      missingFileForces = lib.filter (file: !(builtins.elem file files)) allowedFiles;
      violations = lib.filter (msg: msg != "") [
        (lib.optionalString (
          unexpectedDirectories != [ ]
        ) "anonymous specialisation persists unexpected dir(s): ${formatList unexpectedDirectories}")
        (lib.optionalString (
          unexpectedFiles != [ ]
        ) "anonymous specialisation persists unexpected file(s): ${formatList unexpectedFiles}")
        (lib.optionalString (missingDirectoryForces != [ ])
          "anonymous specialisation lost expected minimal dir allowlist item(s): ${formatList missingDirectoryForces}"
        )
        (lib.optionalString (missingFileForces != [ ])
          "anonymous specialisation lost expected minimal file allowlist item(s): ${formatList missingFileForces}"
        )
      ];
    in
    mkResult (anonymousCfg == null || violations == [ ]) (
      if anonymousCfg == null then
        "no anonymous specialisation configured"
      else if violations == [ ] then
        "anonymous specialisation persistence stays on the minimal allowlist"
      else
        lib.concatStringsSep "; " violations
    );

  checkMullvadTailscaleCoexistence =
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
