{
  lib,
  pkgs,
  hostRegistry,
  allNixosConfigs,
  repoBaseUrl ? "https://github.com/FilipNowakowicz/nixos-config",
  # Extra health assertions per host name, reported after the common ones;
  # the fleet passes each host's `inventoryAssertions` from hosts/<name>/checks.nix.
  hostAssertions ? { },
  healthAssertionsFor ? null,
}:
let
  hostRegistryLib = import ./host-registry.nix;
  invariants = import ./invariants.nix { inherit lib pkgs; };
  driftLib = import ./drift.nix { inherit lib; };

  defaultHealthAssertionsFor =
    name: evaluated:
    let
      commonAssertions = [
        (invariants.stateVersionExplicitlySet evaluated.options)
        invariants.sshHostsEnforceHardenedFail2ban
        invariants.observabilityStaysMinimal
        invariants.obsClientUsesCanonicalUsername
      ];
    in
    commonAssertions
    ++ (hostAssertions.${name} or [ ])
    ++ invariants.mkRegistryAssertions name hostRegistry.${name};

  hostHealth =
    name: cfg:
    let
      assertionsFor =
        if healthAssertionsFor == null then defaultHealthAssertionsFor else healthAssertionsFor;
      results = invariants.evaluateAssertions (assertionsFor name cfg) cfg.config;
      failed = lib.filter (result: !result.passed) results;
    in
    {
      invariantResults = results;
      invariantPassed = builtins.length results - builtins.length failed;
      invariantFailed = builtins.length failed;
      invariantStatus = if failed == [ ] then "pass" else "warn";
    };

  extractHost =
    name: cfg:
    let
      meta = hostRegistry.${name};
      c = cfg.config;
      health = hostHealth name cfg;
      resticBackups = c.services.restic.backups or { };
      tailscaleFirewall = (c.networking.firewall.interfaces or { }).tailscale0 or { };
      # Absent on configs that do not import modules/nixos (e.g. the mini-fleet example).
      driftFacts = c.profiles.drift or { };
    in
    {
      inherit name;
      inherit (meta) system;
      inherit (meta) status;
      closurePath = builtins.unsafeDiscardStringContext (toString c.system.build.toplevel);
      inherit (c.system) stateVersion;
      tailscaleTracked = (meta ? tailscale) || (meta ? tailnetFQDN);
      deployable = meta ? deploy;
      deployUser = meta.deploy.sshUser or null;
      backupClass = meta.backup.class or null;
      homeManagerRole = meta.homeManager.role or null;
      impermanence = (c.environment.persistence or { }) != { };
      openTCPPorts = c.networking.firewall.allowedTCPPorts or [ ];
      openUDPPorts = c.networking.firewall.allowedUDPPorts or [ ];
      tailscaleTCPPorts = tailscaleFirewall.allowedTCPPorts or [ ];
      tailscaleUDPPorts = tailscaleFirewall.allowedUDPPorts or [ ];
      topology = {
        aclTags = lib.optional (meta ? tailscale) "tag:${meta.tailscale.tag}";
        advertisedRoutes = meta.tailscale.advertisedRoutes or [ ];
        acceptedRoutes = meta.tailscale.acceptedRoutes or [ ];
        exitNode = {
          canProvide = meta.tailscale.exitNodeCanProvide or false;
          usesHost = meta.tailscale.exitNodeUse or null;
        };
      };
      resticBackups = lib.mapAttrsToList (backupName: backup: {
        name = backupName;
        repository = backup.repository or null;
        paths = backup.paths or [ ];
        timer = backup.timerConfig.OnCalendar or null;
        initialize = backup.initialize or false;
      }) resticBackups;
      services = {
        openssh = c.services.openssh.enable;
        tailscale = c.services.tailscale.enable;
        firewall = c.networking.firewall.enable;
        fail2ban = c.services.fail2ban.enable;
        syncthing = c.services.syncthing.enable or false;
        nginx = c.services.nginx.enable or false;
        adguard = c.services.adguardhome.enable or false;
        attic = c.services.atticd.enable or false;
        grafana = c.services.grafana.enable or false;
        loki = c.services.loki.enable or false;
        prometheus = c.services.prometheus.enable or false;
        alertmanager = c.services.prometheus.alertmanager.enable or false;
        restic = resticBackups != { };
        hyprland = c.programs.hyprland.enable or false;
        observabilityStack = c.profiles.observability.enable or false;
        observabilityClient = c.profiles.observability-client.enable or false;
        usbguard = c.services.usbguard.enable or false;
        lanzaboote = c.boot.lanzaboote.enable or false;
      };
      trackedServices = driftFacts.trackedServices or [ ];
      drift = {
        tailscaleTag = meta.tailscale.tag or null;
        tailnetFQDN = meta.tailnetFQDN or null;
        tcpPorts = tailscaleFirewall.allowedTCPPorts or [ ];
        # Listeners deliberately not opened on tailscale0; see the
        # profiles.drift.expectedExtraTCPPorts option description.
        expectedExtraTCPPorts = driftFacts.expectedExtraTCPPorts or [ ];
        strictTCPPortSet = meta ? deploy;
        systemdUnits = driftLib.systemdUnits c;
      };
      inherit health;
    };

  hostsData = lib.mapAttrsToList extractHost allNixosConfigs;

  data = {
    schemaVersion = 1;
    inventoryContract = {
      inherit (hostRegistryLib.schema) stableInventoryFields repoLocalInventoryFields;
    };
    hosts = hostsData;
    repository = repoBaseUrl;
  };
in
{
  inherit data;
}
