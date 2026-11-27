# Helpers and schema constants for the host metadata registry.
let
  knownFields = [
    "system"
    "status"
    "deploy"
    "tailnetFQDN"
    "tailscale"
    "homeManager"
    "backup"
    "sops"
    "hardware"
    "remoteBuilder"
    "dnsServer"
  ];

  knownHomeManagerRoles = [
    "desktop"
    "server"
  ];

  knownStatuses = [
    "active"
    "inactive"
    "legacy-supported"
  ];

  stableInventoryFields = [
    "name"
    "system"
    "status"
    "deployable"
    "deployUser"
    "backupClass"
    "homeManagerRole"
    "tailscaleTracked"
    "drift"
  ];

  repoLocalInventoryFields = [
    "closurePath"
    "health"
    "impermanence"
    "openTCPPorts"
    "openUDPPorts"
    "resticBackups"
    "services"
    "stateVersion"
    "tailscaleTCPPorts"
    "tailscaleUDPPorts"
    "trackedServices"
  ];

  ok = cond: msg: if cond then true else throw msg;

  validateHost =
    name: cfg:
    let
      p = n: builtins.hasAttr n cfg;

      unknownFields = builtins.filter (k: !builtins.elem k knownFields) (builtins.attrNames cfg);

      checks = [
        (ok (
          unknownFields == [ ]
        ) "${name}: unknown field(s): ${builtins.concatStringsSep ", " unknownFields}")
        (ok (p "system") "${name}: missing required field 'system'")
        (ok (builtins.isString cfg.system) "${name}.system: must be a string, got ${
          builtins.typeOf (cfg.system or null)
        }")
        (ok (p "status") "${name}: missing required field 'status'")
        (ok (builtins.elem (cfg.status or null) knownStatuses)
          "${name}.status: expected one of ${builtins.toJSON knownStatuses}, got ${
            builtins.toJSON (cfg.status or null)
          }"
        )
        (ok (
          !p "deploy"
          || (builtins.isAttrs cfg.deploy && cfg.deploy ? sshUser && builtins.isString cfg.deploy.sshUser)
        ) "${name}.deploy.sshUser: must be a string")
        (ok (
          !p "tailnetFQDN" || builtins.isString cfg.tailnetFQDN
        ) "${name}.tailnetFQDN: must be a string, got ${builtins.typeOf (cfg.tailnetFQDN or null)}")
        (ok
          (
            !p "tailscale"
            || (
              builtins.isAttrs cfg.tailscale
              && cfg.tailscale ? tag
              && builtins.isString cfg.tailscale.tag
              && (
                !cfg.tailscale ? acceptFrom
                || (
                  builtins.isAttrs cfg.tailscale.acceptFrom
                  && builtins.all (
                    ports:
                    builtins.isList ports && builtins.all (port: builtins.isInt port && port > 0 && port < 65536) ports
                  ) (builtins.attrValues cfg.tailscale.acceptFrom)
                )
              )
              && (!cfg.tailscale ? ip4 || builtins.isString cfg.tailscale.ip4)
              && (
                !cfg.tailscale ? advertisedRoutes
                || (
                  builtins.isList cfg.tailscale.advertisedRoutes
                  && builtins.all builtins.isString cfg.tailscale.advertisedRoutes
                )
              )
              && (
                !cfg.tailscale ? acceptedRoutes
                || (
                  builtins.isList cfg.tailscale.acceptedRoutes
                  && builtins.all builtins.isString cfg.tailscale.acceptedRoutes
                )
              )
              && (!cfg.tailscale ? exitNodeCanProvide || builtins.isBool cfg.tailscale.exitNodeCanProvide)
              && (!cfg.tailscale ? exitNodeUse || builtins.isString cfg.tailscale.exitNodeUse)
            )
          )
          "${name}.tailscale: expected tag string, optional acceptFrom ports, ip4, route lists, and exit-node metadata"
        )
        (ok (
          !p "homeManager"
          || (
            builtins.isAttrs cfg.homeManager
            && builtins.attrNames cfg.homeManager == [ "role" ]
            && builtins.elem cfg.homeManager.role knownHomeManagerRoles
          )
        ) "${name}.homeManager: expected only a role in ${builtins.toJSON knownHomeManagerRoles}")
        (ok
          (
            !p "backup"
            || (
              builtins.isAttrs cfg.backup
              && builtins.elem (cfg.backup.class or null) [
                "critical"
                "standard"
              ]
              && (!cfg.backup ? name || (builtins.isString cfg.backup.name && cfg.backup.name != ""))
              && (!cfg.backup ? restoreTest || builtins.isBool cfg.backup.restoreTest)
              && (!cfg.backup ? restoreDrill || builtins.isBool cfg.backup.restoreDrill)
            )
          )
          "${name}.backup: expected class \"critical\" or \"standard\", optional non-empty string name and optional bool restoreTest/restoreDrill, got ${
            builtins.toJSON (cfg.backup or null)
          }"
        )
        (ok (!p "sops" || builtins.isBool cfg.sops) "${name}.sops: must be a bool")
        (ok (!p "dnsServer" || builtins.isBool cfg.dnsServer) "${name}.dnsServer: must be a bool")
        (ok (
          !p "hardware"
          || (
            builtins.isAttrs cfg.hardware
            && (!cfg.hardware ? diskById || builtins.isString cfg.hardware.diskById)
          )
        ) "${name}.hardware: expected attrset with optional diskById string")
        (ok
          (
            !p "remoteBuilder"
            || (
              builtins.isAttrs cfg.remoteBuilder
              &&
                builtins.attrNames cfg.remoteBuilder == [
                  "maxJobs"
                  "speedFactor"
                  "supportedFeatures"
                ]
              && builtins.isInt cfg.remoteBuilder.maxJobs
              && cfg.remoteBuilder.maxJobs > 0
              && builtins.isInt cfg.remoteBuilder.speedFactor
              && cfg.remoteBuilder.speedFactor > 0
              && builtins.isList cfg.remoteBuilder.supportedFeatures
              && builtins.all builtins.isString cfg.remoteBuilder.supportedFeatures
            )
          )
          "${name}.remoteBuilder: expected positive int maxJobs and speedFactor and a supportedFeatures string list"
        )
      ];

      _valid = builtins.foldl' (a: b: a && b) true checks;
    in
    builtins.seq _valid cfg;

  # The one active host with `dnsServer = true`: its AdGuard Home is the
  # tailnet-wide global DNS nameserver. Zero or several is an error, since
  # every other host needs exactly one resolver to be granted port 53 on.
  dnsServerName =
    registry:
    let
      names = builtins.filter (
        name: (registry.${name}.status or null) == "active" && (registry.${name}.dnsServer or false)
      ) (builtins.attrNames registry);
    in
    if builtins.length names == 1 then
      builtins.head names
    else
      throw "host registry: expected exactly one active host with dnsServer = true, got ${builtins.toJSON names}";
in
{
  schema = {
    inherit
      knownFields
      knownHomeManagerRoles
      knownStatuses
      stableInventoryFields
      repoLocalInventoryFields
      ;
  };

  inherit validateHost dnsServerName;

  # Validates every entry, then the fleet-wide rules (one DNS server).
  validateRegistry =
    registry:
    let
      validated = builtins.mapAttrs validateHost registry;
    in
    builtins.seq (dnsServerName validated) validated;
}
