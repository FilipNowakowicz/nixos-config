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

  activeSopsHostNames =
    hostRegistry:
    uniqueSorted (
      lib.attrNames (
        lib.filterAttrs (
          _: hostMeta: (hostMeta.status or null) == "active" && (hostMeta.sops or true)
        ) hostRegistry
      )
    );

  sopsHostNamesFromYaml =
    yaml:
    let
      lines = lib.splitString "\n" yaml;
      hostRuleForLine =
        line:
        let
          match = builtins.match ".*path_regex: \\^?hosts/([^/]+)/secrets/.*" line;
        in
        if match == null then [ ] else match;
      hostKeyForLine =
        line:
        let
          match = builtins.match ".*&([A-Za-z0-9_-]+)_host .*" line;
        in
        if match == null then [ ] else map (lib.replaceStrings [ "_" ] [ "-" ]) match;
      hostRefForLine =
        line:
        let
          match = builtins.match "[[:space:]]*-[[:space:]]*\\*([A-Za-z0-9_-]+)_host[[:space:]]*" line;
        in
        if match == null then [ ] else map (lib.replaceStrings [ "_" ] [ "-" ]) match;
    in
    {
      rules = uniqueSorted (lib.concatMap hostRuleForLine lines);
      keys = uniqueSorted (lib.concatMap hostKeyForLine lines);
      # Hosts whose key anchor is actually listed as a recipient (`- *name_host`).
      refs = uniqueSorted (lib.concatMap hostRefForLine lines);
    };

  checkSopsRecipientParity =
    hostRegistry: sopsYaml:
    let
      expectedHosts = activeSopsHostNames hostRegistry;
      sopsHosts = sopsHostNamesFromYaml sopsYaml;
      missingRules = lib.filter (host: !(builtins.elem host sopsHosts.rules)) expectedHosts;
      staleRules = lib.filter (host: !(builtins.elem host expectedHosts)) sopsHosts.rules;
      missingKeys = lib.filter (host: !(builtins.elem host sopsHosts.keys)) expectedHosts;
      staleKeys = lib.filter (host: !(builtins.elem host expectedHosts)) sopsHosts.keys;
      unreferencedKeys = lib.filter (
        host: builtins.elem host sopsHosts.keys && !(builtins.elem host sopsHosts.refs)
      ) expectedHosts;
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
        (lib.optionalString (
          unreferencedKeys != [ ]
        ) ".sops.yaml defines but never lists host recipient key(s): ${formatList unreferencedKeys}")
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

  # AdGuard on homeserver-gcp (tag:server) is the tailnet-wide global DNS
  # nameserver, so any tailnet host whose tag is not admitted to it on port 53
  # has NO working external resolver — name resolution times out silently. This
  # recurred twice (gcp-agent, then gcp-builder, whose offloaded builds stalled
  # on cache.nixos.org). Guard against a third recurrence: every tag declared by
  # an active host in the registry must appear in the DNS server's
  # tailscale.acceptFrom with port 53, unless explicitly exempted.
  adguardDnsServerHostName = "homeserver-gcp";
  adguardDnsPort = 53;
  # tag:server is homeserver-gcp's own tag: it *is* the AdGuard host and
  # resolves locally, so it neither needs nor grants itself a :53 inbound rule.
  adguardDnsGrantExemptTags = [ "server" ];

  checkTailnetTagsHaveAdguardDnsGrant =
    hostRegistry:
    let
      dnsServer = hostRegistry.${adguardDnsServerHostName} or { };
      acceptFrom = dnsServer.tailscale.acceptFrom or { };
      tagGranted = tag: builtins.elem adguardDnsPort (acceptFrom.${tag} or [ ]);
      declaredTags = uniqueSorted (
        lib.concatMap (
          hostMeta:
          lib.optional (
            (hostMeta.status or null) == "active" && (hostMeta.tailscale.tag or null) != null
          ) hostMeta.tailscale.tag
        ) (builtins.attrValues hostRegistry)
      );
      missing = lib.filter (
        tag: !(builtins.elem tag adguardDnsGrantExemptTags) && !(tagGranted tag)
      ) declaredTags;
    in
    mkResult (missing == [ ]) (
      if missing == [ ] then
        "every active tailnet tag is admitted to AdGuard DNS (port ${toString adguardDnsPort}) or explicitly exempt"
      else
        "tailnet tag(s) missing AdGuard DNS (port ${toString adguardDnsPort}) grant in ${adguardDnsServerHostName}.tailscale.acceptFrom: ${formatList missing}"
    );

  # Fleet-wide registry policy, checked once by `invariants-registry-security`
  # rather than per host.
  registrySecurityAssertions =
    { hostRegistry, sopsYaml }:
    [
      {
        name = "SOPS recipients match active host registry";
        check = _: checkSopsRecipientParity hostRegistry sopsYaml;
      }
      {
        name = "deploy targets have tailnet addresses";
        check = _: checkDeployTargetsHaveTailnetAddresses hostRegistry;
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

  firewallPorts =
    protocol: rules:
    (rules."allowed${protocol}Ports" or [ ])
    ++ lib.concatMap (r: lib.range r.from r.to) (rules."allowed${protocol}PortRanges" or [ ]);

  interfaceTCPExposureViolations =
    {
      interface,
      ports,
    }:
    cfg:
    let
      globalPorts = firewallPorts "TCP" cfg.networking.firewall;
      interfaces = cfg.networking.firewall.interfaces or { };
      targetPorts = firewallPorts "TCP" (interfaces.${interface} or { });
      globallyOpen = lib.filter (port: builtins.elem port globalPorts) ports;
      missingOnTarget = lib.filter (port: !(builtins.elem port targetPorts)) ports;
      exposedElsewhere = lib.filterAttrs (
        name: value:
        name != interface && lib.any (port: builtins.elem port (firewallPorts "TCP" value)) ports
      ) interfaces;
      elsewhereMessages = lib.mapAttrsToList (
        name: value:
        let
          offending = lib.filter (port: builtins.elem port (firewallPorts "TCP" value)) ports;
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

  # The tailnet ACL (lib/acl.nix) is generated from each host's
  # tailscale.acceptFrom registry entry; the host's own tailscale0 firewall
  # is hand-maintained separately. Keep the two in sync: every port a host
  # actually opens on tailscale0 must be one the ACL admits, and the ACL
  # should not admit ports the host firewall never opens (a port the ACL
  # allows but the firewall drops is dead policy).
  tailscale0FirewallPortsMatchAcceptFrom =
    hostMeta: cfg:
    let
      acceptFrom = hostMeta.tailscale.acceptFrom or { };
      acceptFromPorts = uniqueSorted (builtins.concatLists (builtins.attrValues acceptFrom));
      tsInterface = cfg.networking.firewall.interfaces.tailscale0 or { };
      openedPorts = uniqueSorted ((firewallPorts "TCP" tsInterface) ++ (firewallPorts "UDP" tsInterface));
      missingFromFirewall = lib.filter (p: !(builtins.elem p openedPorts)) acceptFromPorts;
      missingFromAcceptFrom = lib.filter (p: !(builtins.elem p acceptFromPorts)) openedPorts;
      violations = lib.filter (msg: msg != "") [
        (lib.optionalString (missingFromFirewall != [ ])
          "tailscale.acceptFrom admits port(s) not opened on tailscale0: ${formatIntList missingFromFirewall}"
        )
        (lib.optionalString (missingFromAcceptFrom != [ ])
          "tailscale0 opens port(s) not admitted by tailscale.acceptFrom: ${formatIntList missingFromAcceptFrom}"
        )
      ];
    in
    mkResult (violations == [ ]) (
      if violations == [ ] then
        "tailscale0 firewall ports match tailscale.acceptFrom"
      else
        lib.concatStringsSep "; " violations
    );

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

  # NixOS supplies a non-null release even when no module sets this option.
  stateVersionExplicitlySet = options: {
    name = "system.stateVersion is set explicitly";
    check =
      _:
      let
        explicit = options.system.stateVersion.highestPrio < (lib.mkOptionDefault { }).priority;
      in
      mkResult explicit (
        if explicit then
          "system.stateVersion has an explicit definition"
        else
          "system.stateVersion falls back to the nixpkgs default; set it in the host config"
      );
  };

  # A host that joins the tailnet headlessly via an auth key runs `tailscale up`
  # at every boot through tailscaled-autoconnect. Without --reset, drifted
  # persisted prefs make that `up` abort ("changing settings via 'tailscale up'
  # requires mentioning all non-default flags"), so the node never joins and a
  # tailnet-only-SSH/DNS host goes dark (2026-06-21 homeserver-gcp outage; the
  # same wedge latent on gcp-builder/gcp-agent until they too set --reset).
  # Interactive hosts (no authKeyFile) never autoconnect and are exempt.
  tailscaleAutoconnectNormalizesPrefs = {
    name = "tailscale auth-key autoconnect normalizes prefs with --reset";
    check =
      cfg:
      let
        ts = cfg.services.tailscale;
        autoconnect = (ts.enable or false) && (ts.authKeyFile or null) != null;
        hasReset = builtins.elem "--reset" (ts.extraUpFlags or [ ]);
      in
      require (!autoconnect || hasReset)
        "services.tailscale.extraUpFlags must contain \"--reset\" on auth-key autoconnect hosts so boot-time `tailscale up` normalizes prefs and cannot self-wedge on pref drift";
  };

  sshHostsEnforceHardenedFail2ban = {
    name = "SSH hosts enforce hardened fail2ban";
    check = cfg: if !cfg.services.openssh.enable then true else checkHardenedFail2ban cfg;
  };

  observabilityStaysMinimal = {
    name = "registry hosts keep the minimal observability stack";
    check =
      cfg:
      let
        removed = [
          "mimir"
          "tempo"
          "opentelemetry-collector"
        ];
        enabled = lib.filter (name: cfg.services.${name}.enable or false) removed;
      in
      mkResult (enabled == [ ])
        "Removed observability services enabled: ${formatList enabled}. See docs/observability-stack.md#decision-minimal-personal-server-stack; revisiting requires a new reason.";
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

  # On a host with both wait-online providers disabled (main),
  # network-online.target never blocks. A Persistent=true timer then fires its
  # missed run the instant the machine resumes, before Wi-Fi/VPN/DNS are back,
  # and a network unit with no probe or retry fails once and stays stale until
  # the next slot (2026-11-14: restic-backups-local, ResticBackupStale).
  # Network units = ordered after/wanting network-online.target, or restic-*.
  # Each must start with a "*-wait-*" ExecStartPre probe or set Restart=on-failure.
  persistentNetworkTimersSurviveResume = {
    name = "persistent network timers wait for connectivity after resume";
    check =
      cfg:
      let
        services = cfg.systemd.services or { };
        waitOnlineDisabled =
          !(services.systemd-networkd-wait-online.enable or true)
          && !(services.NetworkManager-wait-online.enable or true);
        persistentTimers = lib.filterAttrs (
          _: t: (t.enable or true) && (t.timerConfig.Persistent or false)
        ) (cfg.systemd.timers or { });
        unitFor = name: timer: lib.removeSuffix ".service" (timer.timerConfig.Unit or "${name}.service");
        isNetworkUnit =
          name: svc:
          lib.hasPrefix "restic-" name
          || lib.any (t: t == "network-online.target") (
            (svc.after or [ ]) ++ (svc.wants or [ ]) ++ (svc.requires or [ ])
          );
        hasProbe =
          svc:
          let
            pre = lib.toList (svc.serviceConfig.ExecStartPre or [ ]);
          in
          pre != [ ] && lib.hasInfix "-wait-" (baseNameOf (toString (lib.head pre)));
        unprotected = lib.filter (
          unit:
          let
            svc = services.${unit} or { };
          in
          isNetworkUnit unit svc && !(hasProbe svc) && (svc.serviceConfig.Restart or "no") != "on-failure"
        ) (lib.mapAttrsToList unitFor persistentTimers);
      in
      mkResult (!waitOnlineDisabled || unprotected == [ ]) (
        "Persistent-timer network unit(s) with no leading *-wait-* ExecStartPre or Restart=on-failure "
        + "(network-online.target is a no-op here): ${formatList unprotected}"
      );
  };

  # `nixpkgs` is the flake input every host must resolve `nixpkgs` to.
  nixpkgsRegistryPinnedTo = nixpkgs: {
    name = "nixpkgs registry is pinned to the flake input";
    check =
      cfg:
      let
        expected = builtins.toString nixpkgs;
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

  deployTargetBaseAccessAssertions = [
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
  ];

  deployTargetSopsAssertions = [
    {
      name = "sops uses SSH host key for decryption";
      check =
        cfg:
        require (
          cfg.sops.age.sshKeyPaths != [ ]
        ) "sops.age.sshKeyPaths must contain at least one SSH host key path";
    }
  ];

  deployTargetAccessAssertions = deployTargetBaseAccessAssertions ++ deployTargetSopsAssertions;

  checkNoGlobalTCPPorts =
    ports: cfg:
    let
      globalPorts = firewallPorts "TCP" cfg.networking.firewall;
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
    ++ lib.optionals (hostMeta.tailscale.acceptFrom or null != null) [
      {
        name = "tailscale0 firewall ports match registry acceptFrom";
        check = tailscale0FirewallPortsMatchAcceptFrom hostMeta;
      }
    ];
}
