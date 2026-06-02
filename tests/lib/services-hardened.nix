# Unit tests for the reusable services.hardened module contract.
{ nixpkgs, system }:
let
  pkgs = import nixpkgs { inherit system; };
  inherit (pkgs) lib;

  module = ../../modules/nixos/services/hardened.nix;

  evalConfig =
    modules:
    import "${nixpkgs}/nixos/lib/eval-config.nix" {
      inherit system;
      modules = modules ++ [
        {
          nixpkgs.pkgs = pkgs;
          system.stateVersion = "26.05";
        }
      ];
    };

  serviceConfigFor =
    name:
    (evalConfig [
      module
      {
        services.hardened = {
          baseline = { };

          "forced-extra".extraConfig = {
            PrivateDevices = false;
            ProtectSystem = "full";
            CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";
            AmbientCapabilities = "CAP_NET_BIND_SERVICE";
          };

          "forced-relaxed" = {
            relaxBase = [ "PrivateDevices" ];
            extraConfig.PrivateDevices = false;
          };
        };

        systemd.services = {
          baseline.serviceConfig = {
            ExecStart = "${pkgs.coreutils}/bin/true";
            Type = "oneshot";
          };

          "forced-extra".serviceConfig = {
            ExecStart = "${pkgs.coreutils}/bin/true";
            Type = "oneshot";
          };

          "forced-relaxed".serviceConfig = {
            ExecStart = "${pkgs.coreutils}/bin/true";
            Type = "oneshot";
          };
        };
      }
    ]).config.systemd.services.${name}.serviceConfig;

  baseline = serviceConfigFor "baseline";
  forcedExtra = serviceConfigFor "forced-extra";
  forcedRelaxed = serviceConfigFor "forced-relaxed";

  nullConfig = evalConfig [
    module
    {
      services.hardened.bad.extraConfig.ProtectHome = null;
      systemd.services.bad.serviceConfig = {
        ExecStart = "${pkgs.coreutils}/bin/true";
        Type = "oneshot";
      };
    }
  ];

  failedNullAssertions = lib.filter (assertion: !assertion.assertion) nullConfig.config.assertions;

  tests = {
    baselineAppliesForcedKey = baseline.PrivateDevices == true;
    baselineDropsCapabilities = baseline.CapabilityBoundingSet == "";
    baselineDropsAmbientCapabilities = baseline.AmbientCapabilities == "";
    baselineUsesPrivateKeyring = baseline.KeyringMode == "private";
    forcedKeyWinsOverExtraConfig = forcedExtra.PrivateDevices == true;
    extraConfigOverridesNonForcedDefault = forcedExtra.ProtectSystem == "full";
    extraConfigOverridesCapabilities = forcedExtra.CapabilityBoundingSet == "CAP_NET_BIND_SERVICE";
    relaxBaseAllowsForcedOverride = forcedRelaxed.PrivateDevices == false;
    nullExtraConfigIsRejected =
      failedNullAssertions != [ ]
      && lib.hasInfix "does not support null" (builtins.head failedNullAssertions).message;
  };

  failures = lib.filterAttrs (_: passed: !passed) tests;
in
if failures == { } then
  pkgs.runCommand "services-hardened-tests" { } "touch $out"
else
  throw "services.hardened tests failed:\n${lib.generators.toPretty { } failures}"
