{
  lib,
  pkgs,
  nixpkgs,
  inputs,
  hostRegistry,
  allNixosConfigs,
  ciNixosConfigs,
  invariants,
  self,
}:
let
  # Host-specific invariants and checks live beside the config they guard,
  # in hosts/<name>/checks.nix. Each file may return:
  #   invariants          — layered on the fleet baseline for `invariants-<host>`
  #   inventoryAssertions — the health subset reported in the generated inventory
  #   checks              — extra flake checks, keyed by their check name
  # A registry host without the file still gets the baseline.
  hostChecksArgs = {
    inherit lib pkgs invariants;
    nixosConfigurations = ciNixosConfigs;
  };
  hostChecksFile = hostName: ../hosts + "/${hostName}/checks.nix";
  hostChecks = lib.mapAttrs (hostName: _: import (hostChecksFile hostName) hostChecksArgs) (
    lib.filterAttrs (hostName: _: builtins.pathExists (hostChecksFile hostName)) hostRegistry
  );
  installerChecks = import ../hosts/installer/checks.nix hostChecksArgs;

  # `//` would let one source silently shadow another check of the same name.
  mergeDisjoint = lib.foldl' (
    acc: set:
    let
      duplicates = builtins.attrNames (builtins.intersectAttrs acc set);
    in
    if duplicates == [ ] then
      acc // set
    else
      throw "duplicate flake check name(s): ${lib.concatStringsSep ", " duplicates}"
  ) { };

  # Fleet checks that evaluate this flake's own outputs; see tests/flake/.
  flakeTestArgs = {
    inherit
      lib
      pkgs
      inputs
      self
      ;
  };
  miniFleet = import ../tests/flake/mini-fleet.nix flakeTestArgs;
  flakeTests = map (file: (import file flakeTestArgs).checks) [
    ../tests/flake/observability.nix
    ../tests/flake/backup-retention.nix
    ../tests/flake/public-modules.nix
  ];

  # Every registry host, and main-ci, is checked against this baseline.
  commonSystemInvariants = [
    invariants.observabilityStaysMinimal
    invariants.tailscaleStateIsPersisted
    invariants.tailscaleAutoconnectNormalizesPrefs
    (invariants.nixpkgsRegistryPinnedTo inputs.nixpkgs)
    invariants.rollbackRootInitrdToolsAvailable
    {
      name = "impermanent hosts have matching disko config";
      check = invariants.checkImpermanentHostHasDiskoConfig;
    }
  ];

  # Registry policy follows the host identity. Both option metadata and values
  # must come from the particular system under evaluation (including main-ci).
  hostInvariantCheck =
    checkName: hostName: evaluated:
    invariants.mkInvariantCheck checkName (
      commonSystemInvariants
      ++ [ (invariants.stateVersionExplicitlySet evaluated.options) ]
      ++ invariants.mkRegistryAssertions hostName hostRegistry.${hostName}
      ++ (hostChecks.${hostName}.invariants or [ ])
    ) evaluated.config;

  # Baseline `invariants-<host>` check for every hostRegistry entry, so a new
  # host automatically gets merge-gate coverage without touching this file.
  generatedInvariantChecks = lib.mapAttrs' (
    hostName: _:
    lib.nameValuePair "invariants-${hostName}" (
      hostInvariantCheck hostName hostName allNixosConfigs.${hostName}
    )
  ) hostRegistry;

  # Hosts needing a pre-baked SSH host key for nixos-anywhere/deploy-rs
  # bootstrap: deploy-rs targets (`deploy` present) that are sops-enabled
  # (`sops != false`). `gcp-builder` is excluded via `sops = false`; `main` is
  # excluded because it has no `deploy` entry and never carries a pre-baked
  # host key.
  sopsBootstrapHostNames = builtins.attrNames (
    lib.filterAttrs (_: cfg: (cfg ? deploy) && (cfg.sops or true) != false) hostRegistry
  );

  # `<host>-sops-bootstrap` check for every sopsBootstrapHostNames entry.
  generatedSopsBootstrapChecks = lib.listToAttrs (
    map (
      hostName:
      lib.nameValuePair "${hostName}-sops-bootstrap" (
        invariants.mkSopsBootstrapCheck hostName (../hosts + "/${hostName}/secrets")
      )
    ) sopsBootstrapHostNames
  );
in
{
  # Generated docs samples, exposed as `legacyPackages.<system>.samples.*`.
  inherit (miniFleet) samples;

  inventoryHostAssertions = lib.mapAttrs (_: h: h.inventoryAssertions or [ ]) hostChecks;

  invariantChecks = mergeDisjoint (
    [
      {
        invariants-registry-security = invariants.mkInvariantCheck "registry-security" (
          invariants.registrySecurityAssertions
            {
              inherit hostRegistry;
              sopsYaml = builtins.readFile ../.sops.yaml;
            }
        ) { };

        # CI ships `main-ci` (profiles.ci = true; skipHeavyPackages = true), not
        # the full `main` closure; pin the same invariants to it so the gated
        # build is what gets validated.
        invariants-main-ci = hostInvariantCheck "main-ci" "main" ciNixosConfigs.main-ci;

        invariants-installer =
          invariants.mkInvariantCheck "installer" installerChecks.invariants
            (lib.nixosSystem {
              system = pkgs.stdenv.hostPlatform.system;
              modules = [ ../hosts/installer/default.nix ];
            }).config;
      }
    ]
    ++ lib.mapAttrsToList (_: h: h.checks or { }) hostChecks
    ++ flakeTests
    ++ [
      miniFleet.checks
      generatedInvariantChecks
      generatedSopsBootstrapChecks
    ]
  );

  ciTestsFor = system: {
    homeserver-gcp-smoke = import ../tests/nixos/homeserver-gcp-smoke.nix {
      inherit nixpkgs system;
    };
    profile-security = import ../tests/nixos/profile-security.nix {
      inherit nixpkgs system;
    };
    profile-observability = import ../tests/nixos/profile-observability.nix {
      inherit nixpkgs system;
    };
    profile-hardening = import ../tests/nixos/profile-hardening.nix {
      inherit nixpkgs system;
    };
    profile-runtime-timezone = import ../tests/nixos/profile-runtime-timezone.nix {
      inherit nixpkgs system;
    };
    quiet-shell-smoke = import ../tests/nixos/quiet-shell-smoke.nix {
      inherit nixpkgs system;
    };
    desktop-session = import ../tests/nixos/desktop-session.nix {
      inherit nixpkgs system;
      inherit (inputs) home-manager;
    };
  };
}
