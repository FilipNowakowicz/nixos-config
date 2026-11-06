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
          upstream = { };

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
          # An upstream unit that relaxes a forced key at normal priority.
          upstream.serviceConfig = {
            ExecStart = "${pkgs.coreutils}/bin/true";
            Type = "oneshot";
            NoNewPrivileges = false;
            PrivateTmp = false;
          };

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
  upstream = serviceConfigFor "upstream";
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
    baselineSetsNoNewPrivileges = baseline.NoNewPrivileges == true;
    baselineProtectsSystem = baseline.ProtectSystem == "strict";
    baselineFiltersSyscalls = baseline.SystemCallFilter == [ "@system-service" ];
    baselineRestrictsAddressFamilies =
      baseline.RestrictAddressFamilies == [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
    forcedNoNewPrivilegesBeatsUpstream = upstream.NoNewPrivileges == true;
    forcedPrivateTmpBeatsUpstream = upstream.PrivateTmp == true;
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
