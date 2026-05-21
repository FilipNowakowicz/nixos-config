{ lib, pkgs }:
let
  staticAddressesFor =
    cfg:
    lib.concatMap (
      network:
      let
        address = network.networkConfig.Address or null;
      in
      if address == null then
        [ ]
      else if builtins.isList address then
        address
      else
        [ address ]
    ) (lib.attrValues (cfg.systemd.network.networks or { }));

  stripPrefixLength = address: builtins.head (lib.splitString "/" address);

  hasResticBackup =
    backupName: cfg:
    builtins.hasAttr backupName cfg.services.restic.backups
    && (
      let
        backup = cfg.services.restic.backups.${backupName};
      in
      (backup ? repository && backup.repository != null)
      || (backup ? repositoryFile && backup.repositoryFile != null)
    );
in
rec {
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

  # Create a check derivation that validates config against assertions
  # hostName: string - host identifier for error messages
  # assertions: list of { name: string; check: config -> bool | { passed; message; } }
  # config: the evaluated NixOS config to test
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
    ]
    ++ lib.optionals (hostMeta ? ip) [
      {
        name = "static IP metadata matches configured address";
        check =
          cfg:
          let
            expectedIp = hostMeta.ip;
          in
          lib.any (address: stripPrefixLength address == expectedIp) (staticAddressesFor cfg);
      }
    ];
}
