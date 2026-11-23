{
  inputs,
  self,
  nixpkgs,
  home-manager,
  sops-nix,
  lib,
  hostRegistry,
  overlays,
}:
let
  homeManagerRoleModules = {
    desktop = ../home/users/user/home.nix;
    server = ../home/users/user/server.nix;
  };

  homeManagerHostModules = {
    main = ../home/users/user/main.nix;
  };

  mkHomeManagerImports =
    hostMeta:
    [ homeManagerRoleModules.${hostMeta.homeManager.role} ]
    ++
      lib.optional (builtins.hasAttr hostMeta.name homeManagerHostModules)
        homeManagerHostModules.${hostMeta.name};

  mkNixos =
    host: variantArgs:
    let
      hostMeta = hostRegistry.${host};
      hostMetaWithName = hostMeta // {
        name = host;
      };
      extraModules = variantArgs.extraModules or [ ];
      homeManagerExtraArgs = builtins.removeAttrs variantArgs [
        "extraModules"
        "skipHeavyPackages"
      ];
      homeManagerFleetConfig = {
        fleet = {
          hostName = host;
          skipHeavyPackages = variantArgs.skipHeavyPackages or false;
        };
      };
      configurationRevision = self.dirtyShortRev or self.shortRev or self.dirtyRev or self.rev or null;
    in
    nixpkgs.lib.nixosSystem {
      inherit (hostMeta) system;
      specialArgs = {
        inherit
          inputs
          self
          hostRegistry
          ;
        hostMeta = hostMetaWithName;
      };
      modules = [
        ../hosts/${host}/default.nix
        home-manager.nixosModules.home-manager
        sops-nix.nixosModules.sops
        {
          nixpkgs.overlays = overlays;
        }
        {
          imports = [ ../modules/nixos ];
        }
        {
          system.configurationRevision = lib.mkDefault configurationRevision;
          nix = {
            registry.nixpkgs.flake = inputs.nixpkgs;
            # Keep legacy nixpkgs lookups aligned with the flake-pinned registry entry.
            nixPath = [ "nixpkgs=flake:nixpkgs" ];
          };
        }
        (lib.mkIf (hostMeta ? homeManager) {
          home-manager.sharedModules = [ inputs.sops-nix.homeManagerModules.sops ];
          home-manager.users.user = homeManagerFleetConfig // {
            imports = mkHomeManagerImports hostMetaWithName;
          };
        })
        {
          home-manager.extraSpecialArgs = {
            inherit hostRegistry;
          }
          // homeManagerExtraArgs;
        }
      ]
      ++ extraModules;
    };

  allNixosConfigs = lib.mapAttrs (name: _: mkNixos name { }) hostRegistry;

  ciNixosConfigs = allNixosConfigs // {
    main-ci = mkNixos "main" {
      skipHeavyPackages = true;
      extraModules = [ { profiles.ci = true; } ];
    };
  };

  deployCheckNixosConfigs = ciNixosConfigs;

in
{
  inherit allNixosConfigs ciNixosConfigs deployCheckNixosConfigs;
}
