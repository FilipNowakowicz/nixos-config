{
  lib,
  pkgs,
  hostRegistry,
  allNixosConfigs,
}:
let
  repoBaseUrl = "https://github.com/FilipNowakowicz/NixOS";
  invariants = import ./invariants.nix { inherit lib pkgs; };

  hostHealth =
    name: cfg:
    let
      commonAssertions = [
        {
          name = "has stateVersion";
          check = c: c.system.stateVersion != null;
        }
        {
          name = "SSH hosts enforce hardened fail2ban";
          check =
            c:
            let
              violations = lib.filter (msg: msg != "") [
                (lib.optionalString (!c.services.fail2ban.enable) "services.fail2ban.enable must be true")
                (lib.optionalString (c.services.fail2ban.maxretry > 3) "services.fail2ban.maxretry must be <= 3")
                (lib.optionalString (
                  c.services.fail2ban.bantime != "30m"
                ) "services.fail2ban.bantime must be \"30m\"")
                (lib.optionalString (
                  !c.services.fail2ban."bantime-increment".enable
                ) "services.fail2ban.bantime-increment.enable must be true")
                (lib.optionalString (
                  c.services.fail2ban."bantime-increment".maxtime == null
                ) "services.fail2ban.bantime-increment.maxtime must be set")
              ];
            in
            if !c.services.openssh.enable then true else violations == [ ];
        }
        {
          name = "observability client uses canonical ingest username";
          check =
            c:
            let
              clientProfile = c.profiles.observability-client or { };
              obsProfile = c.profiles.observability or { };
              ingestAuth = obsProfile.ingestAuth or { };
              clientEnabled = clientProfile.enable or false;
              username = ingestAuth.username or "telemetry";
            in
            !clientEnabled || username == "telemetry";
        }
      ];

      hostSpecificAssertions =
        if name == "main" then
          [
            {
              name = "main SSH stays tailnet-only";
              check =
                c:
                c.services.openssh.enable
                && !c.services.openssh.openFirewall
                && c.services.tailscale.enable
                && c.services.tailscale.openFirewall;
            }
            {
              name = "main USBGuard stays deny-default";
              check =
                c:
                let
                  rules = c.services.usbguard.rules or "";
                in
                c.services.usbguard.enable && lib.hasInfix "allow id " rules && lib.hasInfix "reject" rules;
            }
            {
              name = "main local backup covers critical paths";
              check =
                c:
                let
                  backup = c.services.restic.backups.local or null;
                  expectedPaths = [
                    "/home/user/.ssh"
                    "/home/user/.gnupg"
                    "/home/user/nix"
                  ];
                in
                backup != null
                && builtins.all (path: builtins.elem path (backup.paths or [ ])) expectedPaths
                && (backup.passwordFile or "") != ""
                && lib.hasPrefix "/run/secrets/" (backup.passwordFile or "")
                && backup.initialize
                && (backup.timerConfig.OnCalendar or null) == "daily";
            }
          ]
        else if name == "homeserver-gcp" then
          [
            {
              name = "no passwordless sudo";
              check = c: c.security.sudo.wheelNeedsPassword;
            }
            {
              name = "firewall enabled";
              check = c: c.networking.firewall.enable;
            }
            {
              name = "SSH and HTTPS are not globally open";
              check =
                c:
                !(lib.any (port: builtins.elem port (c.networking.firewall.allowedTCPPorts or [ ])) [
                  22
                  443
                ]);
            }
            {
              name = "SSH and HTTPS stay Tailscale-only";
              check =
                c:
                let
                  interfaces = c.networking.firewall.interfaces or { };
                  tailscaleNetwork = interfaces.tailscale0.allowedTCPPorts or [ ];
                in
                builtins.all (port: builtins.elem port tailscaleNetwork) [
                  22
                  443
                ];
            }
          ]
        else
          [ ];

      results = invariants.evaluateAssertions (
        commonAssertions
        ++ hostSpecificAssertions
        ++ invariants.mkRegistryAssertions name hostRegistry.${name}
      ) cfg.config;
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
    in
    {
      inherit name;
      inherit (meta) system;
      inherit (meta) status;
      closurePath = builtins.unsafeDiscardStringContext (toString c.system.build.toplevel);
      inherit (c.system) stateVersion;
      tailscaleTag = meta.tailscale.tag or null;
      tailnetFQDN = meta.tailnetFQDN or null;
      tailscaleTracked = (meta ? tailscale) || (meta ? tailnetFQDN);
      ip = meta.ip or null;
      deployable = meta ? deploy;
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
      profiles = {
        desktop = c.programs.hyprland.enable or false;
        security = c.services.fail2ban.enable or false;
        observability = c.profiles.observability.enable or false;
        observabilityClient = c.profiles.observability-client.enable or false;
      };
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
      inherit health;
    };

  hostsData = lib.mapAttrsToList extractHost allNixosConfigs;

  data = {
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
