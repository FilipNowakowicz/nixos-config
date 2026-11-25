{
  description = "mini-fleet — a fake two-host example of the layering pattern";

  # Replace `nixos-fleet` with whatever name you give this flake's outputs in
  # your own `inputs`. Everything this example imports is a *public* flake
  # output (`nixosModules.*` / `homeModules.*`) — never a path under `hosts/`.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-fleet.url = "github:FilipNowakowicz/nixos-config";
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      nixos-fleet,
      ...
    }:
    let
      system = "x86_64-linux";
    in
    {
      # Two hosts only: one workstation-like, one server-like — exactly the
      # shape needed to show the layering pattern (NixOS profile + Home Manager
      # module on the workstation; hardening + remote observability on the
      # server) without pretending to be a turnkey distro.
      nixosConfigurations = {
        workstation-example = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./hosts/workstation-example
            home-manager.nixosModules.home-manager
            {
              # Layer 1: a public NixOS profile module — desktop baseline.
              imports = [
                nixos-fleet.nixosModules.profiles-desktop
                nixos-fleet.nixosModules.profiles-security
              ];
            }
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                users.demo = {
                  home.stateVersion = "26.05";
                  imports = [
                    # Layer 2: a public Home Manager module, layered on top.
                    nixos-fleet.homeModules.profiles-base
                  ];
                };
              };
            }
          ];
        };

        server-example = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./hosts/server-example
            {
              # Layer 1: hardening — wraps systemd services in a strict
              # confinement baseline (see docs/modules/services-hardened.md).
              imports = [
                nixos-fleet.nixosModules.services-hardened
                nixos-fleet.nixosModules.profiles-security
              ];
            }
            {
              # Layer 2: ship telemetry to a remote observability stack. The
              # client brings in the stack module it configures and turns on
              # only the collectors: a local Prometheus that remote-writes
              # metrics and Alloy for logs. Grafana and Loki stay off.
              imports = [ nixos-fleet.nixosModules.observability-client ];
            }
          ];
        };
      };
    };
}
