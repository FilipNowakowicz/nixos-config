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
    ProtectProc = "invisible";
    ProcSubset = "pid";
    ProtectControlGroups = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectHostname = true;
    ProtectClock = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    KeyringMode = "private";
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

  # mkDefault vs mkForce split.
  #
  # The baseline is split into two groups when it is merged onto a unit's
  # serviceConfig:
  #
  #   * forcedKeys are applied with lib.mkForce so the hardening baseline wins
  #     even when an upstream nixpkgs unit already set the same key. These are
  #     the low-blast-radius "remove privilege/visibility the service does not
  #     need to start" controls — no setuid escalation, private /tmp, private
  #     /dev, and an invisible /proc scoped to the unit's own PIDs. Forcing them
  #     stops an upstream module from silently relaxing the advertised baseline.
  #     A service that genuinely needs one of these relaxed must opt out
  #     explicitly via relaxBase.
  #
  #   * Every other baseline key is applied with lib.mkDefault so a nixpkgs unit
  #     (or the host via extraConfig) can still override runtime-behaviour
  #     controls — syscall/address-family filters, MemoryDenyWriteExecute,
  #     ProtectSystem, namespace restrictions, etc. — which legitimately vary per
  #     service and would break standard operation if forced.
  forcedKeys = [
    "NoNewPrivileges"
    "PrivateTmp"
    "PrivateDevices"
    "ProtectProc"
    "ProcSubset"
  ];

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
              skippedKeys = serviceCfg.relaxBase;
              # Baseline keys still in play after explicit relaxBase omissions.
              activeBase = lib.filterAttrs (k: _: !(lib.elem k skippedKeys)) baseHardening;
              # Core "remove privilege" controls win over nixpkgs defaults (mkForce);
              # relaxBase remains the explicit per-service opt-out for these.
              forcedBase = lib.filterAttrs (k: _: lib.elem k forcedKeys) activeBase;
              # Everything else stays at mkDefault so nixpkgs modules / extraConfig win.
              passiveBase = lib.filterAttrs (k: _: !(lib.elem k forcedKeys)) activeBase;
              # extraConfig values apply at regular priority to override nixpkgs and base.
              activeExtra = serviceCfg.extraConfig;
            in
            lib.mkMerge [
              (lib.mapAttrs (_: lib.mkForce) forcedBase)
              (lib.mapAttrs (_: lib.mkDefault) passiveBase)
              activeExtra
            ];
        }
      ) cfg
    );
  };
}
