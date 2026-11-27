# Evaluate the public module and library exports standalone, by their
# exported names, with nothing from the personal hosts imported.
{
  lib,
  pkgs,
  inputs,
  self,
  ...
}:
let
  # Evaluates the exact `services.hardened.nginx.extraConfig` snippet shown in
  # docs/modules/services-hardened.md against nixpkgs only — no `hosts/` import,
  # no real hostnames or secrets — proving the copyable example works standalone.
  servicesHardenedExampleFixture =
    let
      systemConfig = lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          self.nixosModules.services-hardened
          (
            { pkgs, ... }:
            {
              networking.hostName = "services-hardened-example-fixture";
              system.stateVersion = "26.05";

              systemd.services.nginx.serviceConfig = {
                ExecStart = "${pkgs.coreutils}/bin/true";
                Type = "oneshot";
              };

              services.hardened.nginx.extraConfig = {
                CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";
                AmbientCapabilities = "CAP_NET_BIND_SERVICE";
                ReadWritePaths = [
                  "/var/cache/nginx"
                  "/var/log/nginx"
                ];
              };
            }
          )
        ];
      };
      serviceConfig = systemConfig.config.systemd.services.nginx.serviceConfig;
      evaluated = {
        capabilityBoundingSet = serviceConfig.CapabilityBoundingSet;
        ambientCapabilities = serviceConfig.AmbientCapabilities;
        readWritePaths = serviceConfig.ReadWritePaths;
        # Forced baseline keys must still apply on top of the documented example.
        privateTmp = serviceConfig.PrivateTmp;
        protectSystem = serviceConfig.ProtectSystem;
      };
      expected = {
        capabilityBoundingSet = "CAP_NET_BIND_SERVICE";
        ambientCapabilities = "CAP_NET_BIND_SERVICE";
        readWritePaths = [
          "/var/cache/nginx"
          "/var/log/nginx"
        ];
        privateTmp = true;
        protectSystem = "strict";
      };
    in
    assert lib.assertMsg (
      evaluated == expected
    ) "services-hardened-example-fixture: ${builtins.toJSON evaluated}";
    pkgs.writeText "services-hardened-example-fixture.json" (builtins.toJSON evaluated);

  # Evaluates every `nixosModules.*` and `homeModules.*` export on its own, by
  # its exported name, with nothing else imported — what a downstream flake
  # sees. Iterating over `self` means a new export is covered automatically.
  # A module that reads an option some other personal file declares (the
  # `fleet.*` options once were) fails here instead of in a consumer's build.
  publicModulesStandalone =
    let
      inherit (pkgs.stdenv.hostPlatform) system;
      nixosHost = {
        networking.hostName = "public-module-fixture";
        system.stateVersion = "26.05";
        fileSystems."/" = {
          device = "/dev/disk/by-label/nixos";
          fsType = "ext4";
        };
        boot.loader.grub.devices = [ "/dev/disk/by-label/nixos" ];
      };
      # Turn features on where a module is inert by default, so the check
      # forces what it installs and not only its option declarations.
      homeFeatures = {
        neovim.my.neovim.enable = true;
        profiles-workflow-packs.workflowPacks =
          lib.genAttrs
            [
              "browsing"
              "coding"
              "latex"
              "learning"
            ]
            (_: {
              enable = true;
            });
      };
      nixosDrv =
        _: module:
        (lib.nixosSystem {
          inherit system;
          modules = [
            module
            nixosHost
          ];
        }).config.system.build.toplevel.drvPath;
      homeDrv =
        name: module:
        (inputs.home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            module
            (homeFeatures.${name} or { })
            {
              home = {
                username = "demo";
                homeDirectory = "/home/demo";
                stateVersion = "26.05";
              };
            }
          ];
        }).activationPackage.drvPath;
      modules = lib.mapAttrs (_: lib.mapAttrs (_: builtins.unsafeDiscardStringContext)) {
        nixosModules = lib.mapAttrs nixosDrv self.nixosModules;
        homeModules = lib.mapAttrs homeDrv self.homeModules;
      };
      # The invocations documented in docs/modules/lib-helpers.md, run through
      # the exported `self.lib.*` names. The bare-file boundary tests
      # (`lib-acl`, `lib-dashboards`, `lib-generators`) cover behaviour.
      libExamples = {
        acl = self.lib.acl.mkAcl {
          hostRegistry = {
            laptop.tailscale.tag = "workstation";
            server.tailscale = {
              tag = "server";
              acceptFrom.workstation = [
                22
                443
              ];
            };
          };
        };
        dashboardUid =
          (self.lib.dashboards.mkDashboard {
            uid = "node-health";
            title = "Node health";
            panels = [ ];
          }).uid;
        alloy = self.lib.generators.toAlloyHCL [
          {
            type = "loki.write";
            label = "default";
            body.endpoint = self.lib.generators.nestedBlock {
              url = "http://loki:3100/loki/api/v1/push";
            };
          }
        ];
      };
      expectedAclRule = {
        action = "accept";
        src = [ "tag:workstation" ];
        dst = [
          "tag:server:22"
          "tag:server:443"
        ];
      };
    in
    assert lib.assertMsg (builtins.elem expectedAclRule libExamples.acl.acls)
      "public-modules-standalone: documented lib.acl example lost its workstation -> server rule: ${builtins.toJSON libExamples.acl}";
    assert lib.assertMsg (
      libExamples.dashboardUid == "node-health"
    ) "public-modules-standalone: lib.dashboards.mkDashboard dropped the uid";
    # `endpoint` must render as a block, which `loki.write` requires.
    assert lib.assertMsg (lib.hasInfix "\n  endpoint {\n" libExamples.alloy)
      "public-modules-standalone: lib.generators.toAlloyHCL output: ${libExamples.alloy}";
    pkgs.writeText "public-modules-standalone.json" (
      builtins.toJSON (modules // { lib = libExamples; })
    );

  # Evaluates `nixosModules.profiles-base` standalone: no observability module
  # imported or enabled, and no `inputs`/`self` specialArgs. The public export
  # must not depend on observability internals or this private flake's argument
  # names.
  profilesBaseStandaloneFixture =
    let
      systemConfig = lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          self.nixosModules.profiles-base
          {
            networking.hostName = "profiles-base-standalone-fixture";
            system.stateVersion = "26.05";
          }
        ];
      };
      evaluated = {
        configurationRevision = systemConfig.config.system.configurationRevision;
        hasNixpkgsRegistry = systemConfig.config.nix.registry ? nixpkgs;
        hasExportSystemMetadata = systemConfig.config.system.activationScripts ? exportSystemMetadata;
        zramSwap = systemConfig.config.zramSwap.enable;
      };
      expected = {
        configurationRevision = null;
        hasNixpkgsRegistry = true;
        hasExportSystemMetadata = false;
        zramSwap = true;
      };
    in
    assert lib.assertMsg (
      evaluated == expected
    ) "profiles-base-standalone-fixture: ${builtins.toJSON evaluated}";
    pkgs.writeText "profiles-base-standalone-fixture.json" (builtins.toJSON evaluated);

  # The presets under home/profiles/ take per-user facts (sops files, device
  # IDs) as `fleet.*` options set by the user's entry module, so none of them
  # may point into a particular user's directory.
  homeProfilesUserAgnostic =
    let
      profilesDir = ../../home/profiles;
      offenders = builtins.filter (file: lib.hasInfix "users/user" (builtins.readFile file)) (
        lib.filesystem.listFilesRecursive profilesDir
      );
    in
    assert lib.assertMsg (offenders == [ ])
      "home-profiles-user-agnostic: these presets reference a user directory; take the value as an option and set it from home/users/<name>/ instead: ${
        lib.concatMapStringsSep ", " (
          file: lib.removePrefix "${toString profilesDir}/" (toString file)
        ) offenders
      }";
    pkgs.writeText "home-profiles-user-agnostic" "ok\n";
in
{
  checks = {
    home-profiles-user-agnostic = homeProfilesUserAgnostic;
    services-hardened-example-fixture = servicesHardenedExampleFixture;
    public-modules-standalone = publicModulesStandalone;
    profiles-base-standalone-fixture = profilesBaseStandaloneFixture;
  };
}
