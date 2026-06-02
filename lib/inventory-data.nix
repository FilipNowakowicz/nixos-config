{
  lib,
  pkgs,
  hostRegistry,
  allNixosConfigs,
  repoBaseUrl ? "https://github.com/FilipNowakowicz/nixos-config",
  healthAssertionsFor ? null,
}:
let
  hostRegistryLib = import ./host-registry.nix;
  invariants = import ./invariants.nix { inherit lib pkgs; };

  defaultHealthAssertionsFor =
    name: _cfg:
    let
      commonAssertions = [
        invariants.hasStateVersion
        invariants.sshHostsEnforceHardenedFail2ban
        invariants.obsClientUsesCanonicalUsername
      ];

      hostSpecificAssertions =
        if name == "main" then
          [
            invariants.mainSshIsTailnetOnly
            invariants.mainUsbguardIsDenyDefault
            invariants.mainLocalBackupProtectsCriticalPaths
          ]
        else if name == "homeserver-gcp" then
          invariants.deployTargetAccessAssertions
          ++ [
            invariants.homeserverSshAndHttpsNotGloballyOpen
            invariants.homeserverSshAndHttpsTailscaleOnly
          ]
        else
          [ ];
    in
    commonAssertions
    ++ hostSpecificAssertions
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
      trackedSystemdUnits = lib.filter (unit: unit != "") [
        (lib.optionalString c.services.openssh.enable "sshd.service")
        (lib.optionalString c.services.tailscale.enable "tailscaled.service")
        (lib.optionalString (c.services.nginx.enable or false) "nginx.service")
        (lib.optionalString (c.services.vaultwarden.enable or false) "vaultwarden.service")
        (lib.optionalString (c.services.adguardhome.enable or false) "adguardhome.service")
        (lib.optionalString (c.services.grafana.enable or false) "grafana.service")
        (lib.optionalString (c.services.loki.enable or false) "loki.service")
        (lib.optionalString (c.services.mimir.enable or false) "mimir.service")
        (lib.optionalString (c.services.tempo.enable or false) "tempo.service")
      ];
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
      homeManagerProfiles = meta.homeManager.profiles or [ ];
      impermanence = (c.environment.persistence or { }) != { };
      openTCPPorts = c.networking.firewall.allowedTCPPorts or [ ];
      openUDPPorts = c.networking.firewall.allowedUDPPorts or [ ];
      tailscaleTCPPorts = tailscaleFirewall.allowedTCPPorts or [ ];
      tailscaleUDPPorts = tailscaleFirewall.allowedUDPPorts or [ ];
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
        vaultwarden = c.services.vaultwarden.enable or false;
        syncthing = c.services.syncthing.enable or false;
        nginx = c.services.nginx.enable or false;
        adguard = c.services.adguardhome.enable or false;
        grafana = c.services.grafana.enable or false;
        loki = c.services.loki.enable or false;
        mimir = c.services.mimir.enable or false;
        tempo = c.services.tempo.enable or false;
        restic = resticBackups != { };
        hyprland = c.programs.hyprland.enable or false;
        observabilityStack = c.profiles.observability.enable or false;
        observabilityClient = c.profiles.observability-client.enable or false;
        usbguard = c.services.usbguard.enable or false;
        lanzaboote = c.boot.lanzaboote.enable or false;
      };
      trackedServices =
        if name == "homeserver-gcp" then
          [
            "adguard"
            "nginx"
            "vaultwarden"
            "grafana"
            "loki"
            "mimir"
            "tempo"
          ]
        else
          [ ];
      drift = {
        tailscaleTag = meta.tailscale.tag or null;
        tailnetFQDN = meta.tailnetFQDN or null;
        tcpPorts = tailscaleFirewall.allowedTCPPorts or [ ];
        strictTCPPortSet = meta ? deploy;
        systemdUnits = trackedSystemdUnits;
      };
      inherit health;
    };

  hostsData = lib.mapAttrsToList extractHost allNixosConfigs;

  data = {
    schemaVersion = 1;
    inventoryContract = {
      inherit (hostRegistryLib.schema) stableInventoryFields repoLocalInventoryFields;
      closureSizeBytes = {
        stable = true;
        nullable = true;
        description = "Best-effort Nix closure size in bytes for the host system closure. Null means the closure path was not available in the local Nix store when the inventory package was built.";
      };
    };
    hosts = hostsData;
    repository = repoBaseUrl;
  };
in
{
  inherit data;
  hostSpec = builtins.concatStringsSep "\n" (
    map (host: "${host.name}\t${host.closurePath}") hostsData
  );
}
