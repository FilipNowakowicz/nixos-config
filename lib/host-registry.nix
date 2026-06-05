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

  knownHomeManagerProfiles = [
    "desktop"
  ];

  knownHomeManagerPacks = [
    "browsing"
    "coding"
    "latex"
    "learning"
  ];

  stableInventoryFields = [
    "name"
    "system"
    "status"
    "deployable"
    "deployUser"
    "backupClass"
    "homeManagerRole"
    "homeManagerProfiles"
    "tailscaleTracked"
    "drift"
  ];

  repoLocalInventoryFields = [
    "closurePath"
    "closureSizeBytes"
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
            )
          )
          "${name}.tailscale: expected tag string and optional acceptFrom attrset of ports (1-65535, TCP+UDP)"
        )
        (ok
          (
            !p "homeManager"
            || (
              builtins.isAttrs cfg.homeManager
              && builtins.elem (cfg.homeManager.role or null) knownHomeManagerRoles
              && (
                !cfg.homeManager ? profiles
                || (
                  builtins.isList cfg.homeManager.profiles
                  && builtins.all builtins.isString cfg.homeManager.profiles
                  && builtins.all (profile: builtins.elem profile knownHomeManagerProfiles) cfg.homeManager.profiles
                )
              )
              && (!cfg.homeManager ? enableSpotify || builtins.isBool cfg.homeManager.enableSpotify)
              && (
                !cfg.homeManager ? packs
                || (
                  builtins.isList cfg.homeManager.packs
                  && builtins.all builtins.isString cfg.homeManager.packs
                  && builtins.all (pack: builtins.elem pack knownHomeManagerPacks) cfg.homeManager.packs
                )
              )
            )
          )
          "${name}.homeManager: expected role in ${builtins.toJSON knownHomeManagerRoles}, profiles from ${builtins.toJSON knownHomeManagerProfiles}, and packs from ${builtins.toJSON knownHomeManagerPacks}"
        )
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
            )
          )
          "${name}.backup: expected class \"critical\" or \"standard\" and optional non-empty string name, got ${
            builtins.toJSON (cfg.backup.class or null)
          }"
        )
        (ok (!p "sops" || builtins.isBool cfg.sops) "${name}.sops: must be a bool")
        (ok (
          !p "hardware"
          || (
            builtins.isAttrs cfg.hardware
            && (!cfg.hardware ? diskById || builtins.isString cfg.hardware.diskById)
          )
        ) "${name}.hardware: expected attrset with optional diskById string")
      ];

      _valid = builtins.foldl' (a: b: a && b) true checks;
    in
    builtins.seq _valid cfg;
in
{
  schema = {
    inherit
      knownFields
      knownHomeManagerRoles
      knownStatuses
      knownHomeManagerProfiles
      knownHomeManagerPacks
      stableInventoryFields
      repoLocalInventoryFields
      ;
  };

  inherit validateHost;

  validateRegistry = builtins.mapAttrs validateHost;
}
