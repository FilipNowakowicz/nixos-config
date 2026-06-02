# E2E test for the systemd sandbox hardening score using the services.hardened module.
{ nixpkgs, system }:
let
  pkgs = import nixpkgs { inherit system; };
in
(import "${nixpkgs}/nixos/lib/testing-python.nix" {
  inherit system pkgs;
}).runTest
  {
    name = "profile-hardening-sandbox-score";

    nodes.machine =
      { ... }:
      {
        imports = [ ../../modules/nixos/services/hardened.nix ];

        services.hardened = {
          test-sandboxed.extraConfig = {
            ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
            Type = "simple";
            DynamicUser = true;
            CapabilityBoundingSet = "";
            AmbientCapabilities = "";
            ReadWritePaths = [ ];
            UMask = "0077";
          };

          test-relaxed = {
            relaxBase = [
              "PrivateDevices"
              "ProtectHome"
            ];
            extraConfig = {
              ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
              Type = "simple";
              DynamicUser = true;
            };
          };

          test-forced.extraConfig = {
            PrivateDevices = false;
            ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
            Type = "simple";
            DynamicUser = true;
          };
        };

        systemd.services = {
          test-sandboxed = {
            description = "Sandbox hardening score test service";
            wantedBy = [ "multi-user.target" ];
          };

          test-relaxed = {
            description = "Baseline relaxation test service";
            wantedBy = [ "multi-user.target" ];
          };

          test-forced = {
            description = "Forced hardening priority test service";
            wantedBy = [ "multi-user.target" ];
          };
        };

        environment.systemPackages = [
          pkgs.systemd
          pkgs.python3
        ];
      };

    testScript = ''
      start_all()
      machine.wait_for_unit("test-sandboxed.service")

      # systemd-analyze security outputs a line like:
      #   → Overall exposure level for test-sandboxed.service: 1.9 OK ✓
      result = machine.succeed("systemd-analyze security test-sandboxed.service")
      print(result)

      # Extract numeric score and assert < 2.0
      machine.succeed(
          "systemd-analyze security test-sandboxed.service"
          " | grep -oP 'Overall exposure level.*: \\K[0-9.]+'"
          " | python3 -c 'import sys; score=float(sys.stdin.read().strip());"
          " assert score < 2.0, f\"score {score} >= 2.0 (target: <2.0)\"'"
      )

      machine.wait_for_unit("test-relaxed.service")
      machine.succeed("systemctl cat test-relaxed.service | grep -q 'ProtectSystem=strict'")
      machine.succeed("! systemctl cat test-relaxed.service | grep -q 'PrivateDevices='")
      machine.succeed("! systemctl cat test-relaxed.service | grep -q 'ProtectHome='")

      machine.wait_for_unit("test-forced.service")
      machine.succeed("test \"$(systemctl show -p PrivateDevices --value test-forced.service)\" = yes")
      machine.succeed("test \"$(systemctl show -p KeyringMode --value test-forced.service)\" = private")
    '';
  }
