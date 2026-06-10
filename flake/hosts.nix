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

    homeserver-gcp = mkNixos "homeserver-gcp" {
      extraModules = [
        (
          { lib, modulesPath, ... }:
          {
            # google-compute-config.nix calls readFile on google-guest-configs at
            # eval time, requiring the package to exist in the Nix store. Disable
            # it for flake check; it is still active on real deployments via
            # hardware-configuration.nix → google-compute-image.nix.
            # Must use modulesPath (absolute store path) since the module is
            # imported as a path, not a string, so the key won't match a string.
            disabledModules = [ "${modulesPath}/virtualisation/google-compute-config.nix" ];

            # Stub out the required options that google-compute-config.nix
            # normally provides so NixOS module assertions pass.
            fileSystems."/" = lib.mkDefault {
              device = "/dev/disk/by-label/nixos";
              fsType = "ext4";
            };
            boot.loader.grub.device = lib.mkDefault "/dev/sda";
          }
        )
      ];
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
