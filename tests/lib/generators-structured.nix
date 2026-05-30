# Structured integration tests for Alloy and Grafana generators.
{
  nixpkgs,
  system,
  ...
}:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};
  gen = import ../../lib/generators.nix { inherit lib; };
  dash = import ../../lib/dashboards.nix;

  alloyConfig = gen.toAlloyHCL [
    {
      type = "loki.write";
      label = "target";
      body = {
        endpoint = gen.nestedBlock {
          url = "http://loki:3100";
        };
      };
    }
    {
      type = "loki.source.journal";
      label = "systemd";
      body = {
        forward_to = [ (gen.ref "loki.write.target.receiver") ];
        labels = {
          host = "test-host";
          job = "systemd-journal";
        };
        max_age = "12h";
      };
    }
  ];

  emptyAlloyConfig = gen.toAlloyHCL [ ];

  dashboard = dash.mkDashboard {
    uid = "example-dashboard";
    title = "Example Dashboard";
    panels = [
      (dash.timeseriesPanel {
        id = 1;
        title = "Disk Usage %";
        ds = dash.mimirDS;
        gridPos = dash.gridPos {
          x = 0;
          y = 0;
          w = 12;
          h = 8;
        };
        targets = [
          (dash.target {
            expr = "(node_filesystem_size_bytes - node_filesystem_avail_bytes) / node_filesystem_size_bytes * 100";
            legendFormat = "{{device}}";
          })
        ];
      })
      (dash.timeseriesPanel {
        id = 2;
        title = "CPU Usage %";
        ds = dash.mimirDS;
        gridPos = dash.gridPos {
          x = 12;
          y = 0;
          w = 12;
          h = 8;
        };
        targets = [
          (dash.target {
            expr = "100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)";
            legendFormat = "CPU";
          })
        ];
      })
      (dash.logsPanel {
        id = 3;
        title = "System Logs";
        ds = dash.lokiDS;
        gridPos = dash.gridPos {
          x = 0;
          y = 8;
          w = 24;
          h = 8;
        };
        targets = [
          (dash.target {
            expr = "{job=\"systemd-journal\"}";
          })
        ];
      })
    ];
  };

  dashboardJson = builtins.fromJSON (builtins.toJSON dashboard);

  failures = lib.runTests {
    testAlloyComponentCount = {
      expr = lib.count (line: builtins.match ".* \\{.*" line != null) (lib.splitString "\n" alloyConfig);
      expected = 4;
    };

    testEmptyAlloyConfig = {
      expr = emptyAlloyConfig;
      expected = "";
    };

    testAlloyIncludesTopLevelComponents = {
      expr =
        (lib.hasInfix "loki.write \"target\" {" alloyConfig)
        && (lib.hasInfix "loki.source.journal \"systemd\" {" alloyConfig);
      expected = true;
    };

    testAlloyNestedBlockRendersAsBlock = {
      expr =
        (lib.hasInfix "endpoint {\n    url = \"http://loki:3100\"\n  }" alloyConfig)
        && !(lib.hasInfix "endpoint = {" alloyConfig);
      expected = true;
    };

    testAlloyRefRemainsUnquoted = {
      expr =
        (lib.hasInfix "forward_to = [loki.write.target.receiver,]" alloyConfig)
        && !(lib.hasInfix "\"loki.write.target.receiver\"" alloyConfig);
      expected = true;
    };

    testAlloyInlineObjectPreservesLabels = {
      expr =
        (lib.hasInfix "labels = {\n    host = \"test-host\",\n    job = \"systemd-journal\",\n  }" alloyConfig)
        && (lib.hasInfix "max_age = \"12h\"" alloyConfig);
      expected = true;
    };

    testDashboardShape = {
      expr = builtins.sort builtins.lessThan (builtins.attrNames dashboardJson);
      expected = [
        "id"
        "panels"
        "refresh"
        "schemaVersion"
        "time"
        "timezone"
        "title"
        "uid"
        "version"
      ];
    };

    testDashboardDefaults = {
      expr = {
        inherit (dashboardJson)
          id
          refresh
          schemaVersion
          timezone
          version
          ;
      };
      expected = {
        id = null;
        refresh = "30s";
        schemaVersion = 39;
        timezone = "browser";
        version = 1;
      };
    };

    testDashboardTimeRangeDefaults = {
      expr = dashboardJson.time;
      expected = {
        from = "now-1h";
        to = "now";
      };
    };

    testDashboardPanelCount = {
      expr = lib.length dashboardJson.panels;
      expected = 3;
    };

    testDashboardPanelTypes = {
      expr = map (panel: panel.type) dashboardJson.panels;
      expected = [
        "timeseries"
        "timeseries"
        "logs"
      ];
    };

    testDashboardPanelTitles = {
      expr = map (panel: panel.title) dashboardJson.panels;
      expected = [
        "Disk Usage %"
        "CPU Usage %"
        "System Logs"
      ];
    };

    testDashboardDataSources = {
      expr = map (panel: panel.datasource) dashboardJson.panels;
      expected = [
        dash.mimirDS
        dash.mimirDS
        dash.lokiDS
      ];
    };

    testDashboardGridPositions = {
      expr = map (panel: panel.gridPos) dashboardJson.panels;
      expected = [
        {
          x = 0;
          y = 0;
          w = 12;
          h = 8;
        }
        {
          x = 12;
          y = 0;
          w = 12;
          h = 8;
        }
        {
          x = 0;
          y = 8;
          w = 24;
          h = 8;
        }
      ];
    };

    testDashboardQueries = {
      expr = map (panel: map (target: target.expr) panel.targets) dashboardJson.panels;
      expected = [
        [ "(node_filesystem_size_bytes - node_filesystem_avail_bytes) / node_filesystem_size_bytes * 100" ]
        [ "100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)" ]
        [ "{job=\"systemd-journal\"}" ]
      ];
    };

    testDashboardLegendFormats = {
      expr = map (panel: map (target: target.legendFormat or "") panel.targets) dashboardJson.panels;
      expected = [
        [ "{{device}}" ]
        [ "CPU" ]
        [ "" ]
      ];
    };
  };
in
if failures == [ ] then
  pkgs.runCommand "lib-generators-structured-tests" { } "touch $out"
else
  throw "structured generator tests failed:\n${lib.generators.toPretty { } failures}"
