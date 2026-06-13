{
  inputs,
  self,
  nixpkgs,
  home-manager,
  sops-nix,
  lib,
  hostRegistry,
  lazyactionsOverlay,
  libfprintGoodixOverlay,
}:
let
  pkgs = import nixpkgs {
    system = "x86_64-linux";
    config.allowUnfree = true;
    overlays = [
      lazyactionsOverlay
      libfprintGoodixOverlay
    ];
  };

  homeManagerRoleModules = {
    desktop = ../home/users/user/home.nix;
    server = ../home/users/user/server.nix;
    agent = ../home/users/user/agent.nix;
  };

  homeManagerProfileModules = {
    desktop = ../home/profiles/desktop.nix;
  };

  homeManagerHostModules = {
    main = ../home/users/user/main.nix;
    mac = ../home/users/user/mac.nix;
  };

  mkHomeManagerImports =
    hostMeta:
    let
      hm = hostMeta.homeManager;
      enabledPacks = hm.packs or [ ];
      workflowPackModule = {
        config = lib.mkMerge (
          map (pack: lib.setAttrByPath [ "workflowPacks" pack "enable" ] true) enabledPacks
        );
      };
    in
    [ homeManagerRoleModules.${hm.role} ]
    ++ map (profile: homeManagerProfileModules.${profile}) (hm.profiles or [ ])
    ++
      lib.optional (builtins.hasAttr hostMeta.name homeManagerHostModules)
        homeManagerHostModules.${hostMeta.name}
    ++ lib.optional (enabledPacks != [ ]) workflowPackModule;

  mkNixos =
    host: variantArgs:
    let
      hostMeta = hostRegistry.${host};
      hostMetaWithName = hostMeta // {
        name = host;
      };
      extraModules = variantArgs.extraModules or [ ];
      homeManagerExtraArgs = builtins.removeAttrs variantArgs [ "extraModules" ];
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
          nixpkgs.overlays = [
            lazyactionsOverlay
            libfprintGoodixOverlay
          ];
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
          home-manager.users.user.imports = mkHomeManagerImports hostMetaWithName;
        })
        {
          home-manager.extraSpecialArgs = {
            inherit hostRegistry;
            hostName = host;
            skipHeavyPackages = false;
            enableSpotify = hostMeta.homeManager.enableSpotify or true;
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

in
{
  inherit allNixosConfigs ciNixosConfigs;

  homeConfigurations = {
    user = home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      extraSpecialArgs = {
        inherit inputs;
        skipHeavyPackages = false;
        enableSpotify = true;
      };
      modules = [
        inputs.sops-nix.homeManagerModules.sops
        ../home/users/user/home.nix
        ../home/profiles/desktop.nix
      ];
    };

    "user@wsl" = home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      extraSpecialArgs = {
        inherit inputs;
        skipHeavyPackages = false;
        enableSpotify = true;
      };
      modules = [
        ../home/users/user/wsl.nix
      ];
    };
  };
}
