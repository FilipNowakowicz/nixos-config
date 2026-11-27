{
  config,
  lib,
  ...
}:
let
  cfg = config.profiles.observability;
  dash = import ../../../../lib/dashboards.nix;

  datasourceBackend =
    datasource:
    let
      uid = datasource.uid or "";
      type = datasource.type or "";
    in
    if uid == "prometheus" || type == "prometheus" then
      "prometheus"
    else if uid == "loki" || type == "loki" then
      "loki"
    else
      null;

  datasourceDescription =
    datasource:
    if datasource == null then
      "missing datasource"
    else
      "${datasource.type or "unknown-type"}/${datasource.uid or "unknown-uid"}";

  enabledDashboards = lib.filterAttrs (_: dashboard: dashboard.enable) cfg.dashboards;
  # Row panels have no datasource of their own; check the panels they carry.
  leafPanels = lib.concatMap (
    panel: if (panel.type or null) == "row" then leafPanels (panel.panels or [ ]) else [ panel ]
  );
  panelDatasourceRefs = lib.flatten (
    lib.mapAttrsToList (
      dashboardName: dashboard:
      map (panel: {
        inherit dashboardName;
        panelId = panel.id or null;
        panelTitle = panel.title or "<untitled>";
        datasource = panel.datasource or null;
        backend = datasourceBackend (panel.datasource or { });
      }) (leafPanels (dashboard.definition.panels or [ ]))
    ) enabledDashboards
  );
  enabledBackends = {
    inherit (cfg) loki;
    prometheus.enable = cfg.collectors.metrics.enable;
  };
  backendEnabled = backend: enabledBackends.${backend}.enable or false;
  formatPanelRef =
    ref:
    "${ref.dashboardName} panel ${builtins.toString ref.panelId} (${ref.panelTitle}) uses ${datasourceDescription ref.datasource}";
  unknownDatasourceRefs = lib.filter (ref: ref.backend == null) panelDatasourceRefs;
  disabledBackendRefs = lib.filter (
    ref: ref.backend != null && !(backendEnabled ref.backend)
  ) panelDatasourceRefs;

  securityEventsDashboard = dash.mkDashboard {
    uid = "security-events";
    title = "Security Events";
    timeFrom = "now-24h";
    panels = [
      (dash.logsPanel {
        id = 20;
        title = "Recent Audit Events";
        ds = dash.lokiDS;
        gridPos = dash.gridPos {
          x = 0;
          y = 0;
          w = 24;
          h = 8;
        };
        targets = [
          (dash.target {
            expr = "{job=\"audit-journal\"}";
          })
        ];
      })
      (dash.logsPanel {
        id = 21;
        title = "Sudo Activity";
        ds = dash.lokiDS;
        gridPos = dash.gridPos {
          x = 0;
          y = 8;
          w = 12;
          h = 8;
        };
        targets = [
          (dash.target {
            expr = "{job=\"audit-journal\",audit_event_type=\"sudo\"}";
          })
        ];
      })
      (dash.logsPanel {
        id = 22;
        title = "SSH Sessions";
        ds = dash.lokiDS;
        gridPos = dash.gridPos {
          x = 12;
          y = 8;
          w = 12;
          h = 8;
        };
        targets = [
          (dash.target {
            expr = "{job=\"audit-journal\",audit_event_type=\"ssh\"}";
          })
        ];
      })
      (dash.logsPanel {
        id = 23;
        title = "Service Failures";
        ds = dash.lokiDS;
        gridPos = dash.gridPos {
          x = 0;
          y = 16;
          w = 24;
          h = 8;
        };
        targets = [
          (dash.target {
            expr = "{job=\"audit-journal\",audit_event_type=\"service_failure\"}";
          })
        ];
      })
    ];
  };

  dashboardSubmodule = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to render this dashboard to /etc/grafana-dashboards.";
      };
      definition = lib.mkOption {
        type = lib.types.attrs;
        description = "Grafana dashboard attrset (typically built via lib/dashboards.nix).";
      };
    };
  };
in
{
  options.profiles.observability.dashboards = lib.mkOption {
    type = lib.types.attrsOf dashboardSubmodule;
    default = { };
    description = ''
      Grafana dashboards to render under /etc/grafana-dashboards/<name>.json.
      The built-in `security-events` dashboard is pre-registered (off by
      default); toggle it via `dashboards.security-events.enable`. Add new
      dashboards by setting `dashboards.<name>.definition`.
    '';
  };

  config = lib.mkIf (cfg.enable && cfg.grafana.enable) {
    assertions = [
      {
        assertion = unknownDatasourceRefs == [ ];
        message = "Grafana dashboard panel datasource(s) do not map to a known observability backend: ${
          lib.concatMapStringsSep "; " formatPanelRef unknownDatasourceRefs
        }";
      }
      {
        assertion = disabledBackendRefs == [ ];
        message = "Grafana dashboard panel datasource(s) reference disabled observability backend(s): ${
          lib.concatMapStringsSep "; " (
            ref: "${formatPanelRef ref}, but profiles.observability.${ref.backend}.enable is false"
          ) disabledBackendRefs
        }";
      }
    ];

    profiles.observability.dashboards.security-events = {
      enable = lib.mkDefault false;
      definition = securityEventsDashboard;
    };

    environment.etc = lib.mapAttrs' (name: dashboard: {
      name = "grafana-dashboards/${dashboard.definition.uid or name}.json";
      value.text = builtins.toJSON dashboard.definition;
    }) (lib.filterAttrs (_: d: d.enable) cfg.dashboards);
  };
}
