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
  # Home Manager entry modules follow a naming convention under
  # home/users/user/: `<role>.nix` for the registry's `homeManager.role`, plus
  # `<host>.nix` when that file exists. Shared building blocks there
  # (common.nix, secrets.nix, codex.nix) are never named after a role or host.
  mkHomeManagerImports =
    host: hostMeta:
    let
      hostModule = ../home/users/user + "/${host}.nix";
    in
    [ (../home/users/user + "/${hostMeta.homeManager.role}.nix") ]
    ++ lib.optional (builtins.pathExists hostModule) hostModule;

  mkNixos =
    host:
    {
      extraModules ? [ ],
    }:
    let
      hostMeta = hostRegistry.${host};
      hostMetaWithName = hostMeta // {
        name = host;
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
        (
          { config, ... }:
          lib.mkIf (hostMeta ? homeManager) {
            home-manager.sharedModules = [ inputs.sops-nix.homeManagerModules.sops ];
            home-manager.users.${config.profiles.primaryUser} = {
              imports = mkHomeManagerImports host hostMeta;
            };
          }
        )
        {
          home-manager.extraSpecialArgs = {
            # `self` lets the user modules import public `homeModules.*` by
            # their exported names.
            inherit hostRegistry self;
          };
        }
      ]
      ++ extraModules;
    };

  allNixosConfigs = lib.mapAttrs (name: _: mkNixos name { }) hostRegistry;

  # `profiles.ci` also turns on Home Manager's `fleet.skipHeavyPackages`, which
  # defaults from it (home/profiles/fleet.nix).
  ciNixosConfigs = allNixosConfigs // {
    main-ci = mkNixos "main" {
      extraModules = [ { profiles.ci = true; } ];
    };
  };

in
{
  inherit allNixosConfigs ciNixosConfigs;
}
