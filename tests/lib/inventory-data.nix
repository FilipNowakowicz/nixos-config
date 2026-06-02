# Unit tests for the generated inventory JSON contract.
{
  nixpkgs,
  system,
  ...
}:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};

  hostRegistry = {
    alpha = {
      system = "x86_64-linux";
      status = "active";
      deploy.sshUser = "user";
      tailnetFQDN = "alpha.example.ts.net";
      tailscale = {
        tag = "server";
        acceptFrom.workstation = [ 22 ];
      };
      backup.class = "standard";
      homeManager = {
        role = "server";
        profiles = [ ];
      };
    };
  };

  config = {
    system = {
      stateVersion = "26.05";
      build.toplevel = "/nix/store/00000000000000000000000000000000-alpha-system";
    };
    environment.persistence = { };
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ 80 ];
      allowedUDPPorts = [ ];
      interfaces.tailscale0 = {
        allowedTCPPorts = [ 22 ];
        allowedUDPPorts = [ ];
      };
    };
    services = {
      openssh.enable = true;
      tailscale.enable = true;
      fail2ban.enable = true;
      restic.backups.local = {
        repository = "/backup";
        paths = [ "/var/lib/example" ];
        timerConfig.OnCalendar = "daily";
        initialize = true;
      };
    };
    programs.hyprland.enable = false;
    profiles = {
      observability.enable = false;
      observability-client.enable = true;
    };
    boot.lanzaboote.enable = false;
  };

  inventory = import ../../lib/inventory-data.nix {
    inherit
      lib
      pkgs
      hostRegistry
      ;
    allNixosConfigs.alpha.config = config;
    repoBaseUrl = "https://example.invalid/fleet";
    healthAssertionsFor = _name: _cfg: [
      {
        name = "test assertion";
        check = _: true;
      }
    ];
  };

  inherit (inventory) data;
  host = builtins.head data.hosts;

  failures = lib.runTests {
    testSchemaVersion = {
      expr = data.schemaVersion;
      expected = 1;
    };

    testRepositoryIsConfigurable = {
      expr = data.repository;
      expected = "https://example.invalid/fleet";
    };

    testHostSpecIncludesClosurePath = {
      expr = inventory.hostSpec;
      expected = "alpha\t/nix/store/00000000000000000000000000000000-alpha-system";
    };

    testStableFieldsAreDeclared = {
      expr = data.inventoryContract.stableInventoryFields;
      expected = [
        "name"
        "system"
        "status"
        "deployable"
        "deployUser"
        "backupClass"
        "homeManagerRole"
        "homeManagerProfiles"
        "tailscaleTracked"
        "drift"
      ];
    };

    testClosureSizeContractIsNullable = {
      expr = data.inventoryContract.closureSizeBytes.nullable;
      expected = true;
    };

    testPublicHostFields = {
      expr = {
        inherit (host)
          name
          system
          status
          deployable
          deployUser
          backupClass
          homeManagerRole
          homeManagerProfiles
          tailscaleTracked
          ;
      };
      expected = {
        name = "alpha";
        system = "x86_64-linux";
        status = "active";
        deployable = true;
        deployUser = "user";
        backupClass = "standard";
        homeManagerRole = "server";
        homeManagerProfiles = [ ];
        tailscaleTracked = true;
      };
    };

    testRepoLocalFieldsStillExported = {
      expr = {
        inherit (host)
          closurePath
          openTCPPorts
          tailscaleTCPPorts
          ;
        serviceRestic = host.services.restic;
        healthStatus = host.health.invariantStatus;
      };
      expected = {
        closurePath = "/nix/store/00000000000000000000000000000000-alpha-system";
        openTCPPorts = [ 80 ];
        tailscaleTCPPorts = [ 22 ];
        serviceRestic = true;
        healthStatus = "pass";
      };
    };
  };
in
if failures == [ ] then
  pkgs.runCommand "lib-inventory-data-tests" { } "touch $out"
else
  throw "lib/inventory-data.nix tests failed:\n${lib.generators.toPretty { } failures}"
