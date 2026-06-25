# Clean-clone boundary test for lib/dashboards.nix.
#
# Imports the file with nothing but stock `nixpkgs.lib` — no `pkgs`,
# `hostRegistry`, or any fleet context — proving the Grafana dashboard
# builders evaluate as a standalone reusable library (`flake.lib.dashboards`).
{
  nixpkgs,
  system,
  ...
}:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};

  # The public surface: imported exactly as an external flake would consume
  # `inputs.nixos-fleet.lib.dashboards`, with zero arguments.
  dash = import ../../lib/dashboards.nix;

  sampleDashboard = dash.mkDashboard {
    uid = "sample";
    title = "Sample";
    panels = [
      (dash.timeseriesPanel {
        id = 1;
        title = "CPU idle";
        ds = dash.mimirDS;
        gridPos = dash.gridPos { };
        targets = [
          (dash.target {
            expr = ''node_cpu_seconds_total{${dash.hostSelector "main"},mode="idle"}'';
            legendFormat = "idle";
          })
        ];
      })
    ];
  };

  failures = lib.runTests {
    # gridPos applies documented defaults.
    testGridPosDefaults = {
      expr = dash.gridPos { };
      expected = {
        x = 0;
        y = 0;
        w = 12;
        h = 8;
      };
    };

    # Datasource helper produces a typed reference.
    testDatasource = {
      expr = dash.datasource "loki" "loki";
      expected = dash.lokiDS;
    };

    # hostSelector emits a PromQL/LogQL label selector.
    testHostSelector = {
      expr = dash.hostSelector "main";
      expected = ''host="main"'';
    };

    # Optional target fields are omitted unless set (back-compat contract).
    testTargetOmitsOptional = {
      expr = builtins.attrNames (dash.target { expr = "up"; });
      expected = [
        "expr"
        "legendFormat"
        "refId"
      ];
    };

    # mkDashboard fixes the schema/version envelope every dashboard relies on.
    testDashboardEnvelope = {
      expr = {
        inherit (sampleDashboard)
          id
          schemaVersion
          version
          timezone
          ;
        panelType = (builtins.head sampleDashboard.panels).type;
      };
      expected = {
        id = null;
        schemaVersion = 39;
        version = 1;
        timezone = "browser";
        panelType = "timeseries";
      };
    };
  };
in
assert failures == [ ];
pkgs.runCommand "lib-dashboards-tests" { } "touch $out"
