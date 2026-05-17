{
  config,
  lib,
  ...
}:
let
  baseHardening = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectControlGroups = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectHostname = true;
    ProtectClock = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    RestrictSUIDSGID = true;
    RestrictRealtime = true;
    RestrictNamespaces = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" ];
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
    ];
  };

  hardenedServiceType = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Apply the hardening baseline to this service.";
      };

      relaxBase = lib.mkOption {
        type = lib.types.listOf (lib.types.enum (lib.attrNames baseHardening));
        default = [ ];
        description = ''
          Baseline hardening keys to omit entirely for this service, leaving the
          upstream unit or systemd default in place.
        '';
        example = [
          "MemoryDenyWriteExecute"
          "RestrictNamespaces"
        ];
      };

      extraConfig = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = ''
          Additional serviceConfig options merged on top of the baseline.
          Use relaxBase when a baseline key should be omitted instead of
          overridden.
        '';
        example = lib.literalExpression ''
          {
            BindReadOnlyPaths = [ "/etc/ssl/certs" ];
            AmbientCapabilities = "CAP_NET_BIND_SERVICE";
          }
        '';
      };
    };
  };

  cfg = config.services.hardened;
in
{
  options.services.hardened = lib.mkOption {
    type = lib.types.attrsOf hardenedServiceType;
    default = { };
    description = ''
      Apply a security hardening baseline to the named systemd services.
      Each entry merges the base sandbox options with per-service extraConfig
      and optional relaxBase omissions.
    '';
    example = lib.literalExpression ''
      {
        nginx = {
          relaxBase = [ "MemoryDenyWriteExecute" ];
          extraConfig.AmbientCapabilities = "CAP_NET_BIND_SERVICE";
        };
      }
    '';
  };

  config = {
    assertions = lib.mapAttrsToList (name: serviceCfg: {
      assertion = lib.all (v: v != null) (lib.attrValues serviceCfg.extraConfig);
      message = "services.hardened.${name}.extraConfig does not support null; use relaxBase to omit baseline keys.";
    }) cfg;

    systemd.services = lib.mkMerge (
      lib.mapAttrsToList (
        name: serviceCfg:
        lib.mkIf serviceCfg.enable {
          ${name}.serviceConfig =
            let
              skippedKeys = serviceCfg.relaxBase ++ lib.attrNames serviceCfg.extraConfig;
              # Base options not touched by extraConfig: apply at mkDefault so nixpkgs modules win.
              passiveBase = lib.filterAttrs (k: _: !(lib.elem k skippedKeys)) baseHardening;
              # extraConfig values apply at regular priority to override nixpkgs and base.
              activeExtra = serviceCfg.extraConfig;
            in
            lib.mkMerge [
              (lib.mapAttrs (_: lib.mkDefault) passiveBase)
              activeExtra
            ];
        }
      ) cfg
    );
  };
}
