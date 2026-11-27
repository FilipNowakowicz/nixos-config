# The examples/mini-fleet flake and the docs samples generated from it.
{
  lib,
  pkgs,
  inputs,
  self,
  ...
}:
let
  # The mini-fleet example flake, its `outputs` evaluated with `nixos-fleet`
  # bound to this checkout and the other inputs to the root pins.
  miniFleetFlake = import ../../examples/mini-fleet/flake.nix;
  miniFleetExample = miniFleetFlake.outputs {
    inherit (inputs) nixpkgs home-manager;
    nixos-fleet = self;
  };

  # docs/samples/inventory.sample.json: lib/inventory-data.nix over the
  # mini-fleet server and a synthetic registry entry. The sample shows the
  # inventory schema on a fake host instead of tracking the personal
  # homeserver, so it changes only when the generator, the invariants or the
  # example change. The closure path embeds the nixpkgs revision, so it is
  # replaced to keep weekly lock updates from touching the sample.
  inventorySample =
    let
      inventory = import ../../lib/inventory-data.nix {
        inherit lib pkgs;
        hostRegistry.server-example = {
          system = "x86_64-linux";
          status = "active";
          deploy.sshUser = "deploy";
          tailnetFQDN = "server-example.example.ts.net";
          tailscale = {
            tag = "server";
            acceptFrom.workstation = [ 22 ];
          };
          backup.class = "standard";
        };
        # The example server plus what that registry entry promises: SSH and
        # Tailscale for deploys, a tailnet-only SSH port and a Restic job.
        allNixosConfigs.server-example = miniFleetExample.nixosConfigurations.server-example.extendModules {
          modules = [
            {
              services = {
                openssh = {
                  enable = true;
                  openFirewall = false;
                };
                tailscale.enable = true;
                restic.backups.local = {
                  repository = "/srv/backup";
                  paths = [ "/var/lib/demo-app" ];
                  # Not in the sample; kept short so the plaintext-secret scan
                  # doesn't read it as an inline password.
                  passwordFile = "/etc/restic.key";
                  timerConfig.OnCalendar = "daily";
                  initialize = true;
                };
              };
              networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 22 ];
            }
          ];
        };
      };
      normalizeHost =
        host:
        host
        // {
          closurePath = "/nix/store/00000000000000000000000000000000-nixos-system-server-example";
        };
    in
    pkgs.runCommand "inventory.sample.json"
      {
        nativeBuildInputs = [ pkgs.jq ];
        sample = builtins.toJSON (inventory.data // { hosts = map normalizeHost inventory.data.hosts; });
        passAsFile = [ "sample" ];
      }
      ''
        jq -S . "$samplePath" > "$out"
      '';

  # The committed samples must equal what the generators produce, compared
  # as JSON so formatting is irrelevant. Regenerate with the commands in
  # docs/public-adoption.md#sample-artifacts.
  docsSamples =
    pkgs.runCommand "docs-samples"
      {
        nativeBuildInputs = [ pkgs.jq ];
        acl = self.packages.${pkgs.stdenv.hostPlatform.system}.tailscale-acl;
      }
      ''
        compare() {
          if ! diff -u <(jq -S . "$2") <(jq -S . "$3"); then
            echo "docs/samples/$1 differs from the generator; regenerate it (docs/public-adoption.md#sample-artifacts)" >&2
            exit 1
          fi
        }
        compare inventory.sample.json ${../../docs/samples/inventory.sample.json} ${inventorySample}
        compare tailscale-acl.sample.json ${../../docs/samples/tailscale-acl.sample.json} "$acl"
        touch "$out"
      '';

  # Evaluates the `examples/mini-fleet` flake's own `outputs` function, with
  # its `nixos-fleet` input bound to this checkout and the other inputs to the
  # root pins. CI therefore checks the configurations the example actually
  # defines, not a copy of its module list, and asserts the behaviour its
  # README and comments describe.
  miniFleetExampleFixture =
    let
      exampleFlake = miniFleetFlake;
      example = miniFleetExample;
      workstation = example.nixosConfigurations.workstation-example.config;
      server = example.nixosConfigurations.server-example.config;
      demoHome = workstation.home-manager.users.demo;
      evaluated = {
        upstreamURL = exampleFlake.inputs.nixos-fleet.url;
        hostNames = map (c: c.networking.hostName) [
          workstation
          server
        ];
        workstation = {
          desktop = workstation.programs.hyprland.enable;
          # Set by profiles-security, not NixOS defaults.
          security = workstation.services.fail2ban.enable && workstation.networking.nftables.enable;
          # homeModules.profiles-base installs the core CLI set.
          homeHasRipgrep = builtins.any (p: (p.pname or "") == "ripgrep") demoHome.home.packages;
        };
        server = {
          security = server.services.fail2ban.enable && server.networking.nftables.enable;
          demoAppCapabilities = server.systemd.services.demo-app.serviceConfig.CapabilityBoundingSet;
          demoAppPrivateTmp = server.systemd.services.demo-app.serviceConfig.PrivateTmp;
          # Shipping only: local Prometheus remote-writes, Alloy ships logs,
          # and neither Grafana nor Loki runs here.
          prometheus = server.services.prometheus.enable;
          metricsURL = (builtins.head server.services.prometheus.remoteWrite).url;
          alloy = server.services.alloy.enable;
          grafana = server.services.grafana.enable;
          loki = server.services.loki.enable;
        };
      };
      expected = {
        upstreamURL = "github:FilipNowakowicz/nixos-config";
        hostNames = [
          "workstation-example"
          "server-example"
        ];
        workstation = {
          desktop = true;
          security = true;
          homeHasRipgrep = true;
        };
        server = {
          security = true;
          demoAppCapabilities = "";
          demoAppPrivateTmp = true;
          prometheus = true;
          metricsURL = "https://observability.example.ts.net/ingest/metrics";
          alloy = true;
          grafana = false;
          loki = false;
        };
      };
      # Forcing the toplevels runs every NixOS assertion on both hosts; the
      # Home Manager activation proves the layered user config evaluates.
      derivations = map builtins.unsafeDiscardStringContext [
        workstation.system.build.toplevel.drvPath
        server.system.build.toplevel.drvPath
        demoHome.home.activationPackage.drvPath
      ];
    in
    assert lib.assertMsg (evaluated == expected)
      "mini-fleet-example-fixture: expected ${builtins.toJSON expected}, got ${builtins.toJSON evaluated}";
    pkgs.writeText "mini-fleet-example-fixture.json" (
      builtins.toJSON (evaluated // { inherit derivations; })
    );
in
{
  # Exposed as `legacyPackages.<system>.samples.*`.
  samples.inventory = inventorySample;

  checks = {
    mini-fleet-example-fixture = miniFleetExampleFixture;
    docs-samples = docsSamples;
  };
}
