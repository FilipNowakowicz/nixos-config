# Builder helpers for Grafana dashboards as typed Nix attrsets.

{
  # Grid position builder
  gridPos =
    {
      x ? 0,
      y ? 0,
      w ? 12,
      h ? 8,
    }:
    {
      inherit
        x
        y
        w
        h
        ;
    };

  # Standard datasource references
  mimirDS = {
    uid = "mimir";
    type = "prometheus";
  };
  lokiDS = {
    uid = "loki";
    type = "loki";
  };
  tempoDS = {
    uid = "tempo";
    type = "tempo";
  };

  # Generic datasource reference
  datasource = uid: type: { inherit uid type; };

  # PromQL/LogQL label selector for scoping queries to a specific host.
  # Usage: expr = "node_cpu_seconds_total{${dash.hostSelector \"main\"},mode=\"idle\"}";
  hostSelector = host: ''host="${host}"'';

  # Query target builder
  target =
    {
      expr,
      legendFormat ? "",
      refId ? "A",
    }:
    {
      inherit expr legendFormat refId;
    };

  # Timeseries panel builder
  timeseriesPanel =
    {
      id,
      title,
      ds,
      targets,
      gridPos,
      unit ? null,
      min ? null,
      max ? null,
      decimals ? null,
      legendDisplayMode ? "list",
    }:
    {
      inherit
        id
        title
        targets
        gridPos
        ;
      type = "timeseries";
      datasource = ds;
      options = {
        legend = {
          displayMode = legendDisplayMode;
          placement = "bottom";
        };
        tooltip.mode = "multi";
      };
      fieldConfig.defaults = {
        custom = {
          drawStyle = "line";
          fillOpacity = 12;
          lineInterpolation = "smooth";
          lineWidth = 2;
          pointSize = 4;
          showPoints = "never";
        };
        thresholds.mode = "absolute";
      }
      // (if unit != null then { inherit unit; } else { })
      // (if min != null then { inherit min; } else { })
      // (if max != null then { inherit max; } else { })
      // (if decimals != null then { inherit decimals; } else { });
    };

  # Stat panel builder for current health tiles.
  statPanel =
    {
      id,
      title,
      ds,
      targets,
      gridPos,
      unit ? null,
      min ? null,
      max ? null,
      decimals ? 1,
      colorMode ? "value",
      graphMode ? "area",
    }:
    {
      inherit
        id
        title
        targets
        gridPos
        ;
      type = "stat";
      datasource = ds;
      options = {
        reduceOptions = {
          values = false;
          calcs = [ "lastNotNull" ];
          fields = "";
        };
        orientation = "auto";
        textMode = "auto";
        inherit colorMode graphMode;
        justifyMode = "auto";
      };
      fieldConfig.defaults = {
        inherit decimals;
        thresholds = {
          mode = "absolute";
          steps = [
            {
              color = "green";
              value = null;
            }
            {
              color = "orange";
              value = 70;
            }
            {
              color = "red";
              value = 90;
            }
          ];
        };
      }
      // (if unit != null then { inherit unit; } else { })
      // (if min != null then { inherit min; } else { })
      // (if max != null then { inherit max; } else { });
    };

  # Logs panel builder
  logsPanel =
    {
      id,
      title,
      ds,
      targets,
      gridPos,
    }:
    {
      inherit
        id
        title
        targets
        gridPos
        ;
      type = "logs";
      datasource = ds;
    };

  # Dashboard builder with sensible defaults
  mkDashboard =
    {
      uid,
      title,
      panels,
      refresh ? "30s",
      timeFrom ? "now-1h",
      timeTo ? "now",
    }:
    {
      id = null;
      inherit
        uid
        title
        panels
        refresh
        ;
      timezone = "browser";
      schemaVersion = 39;
      version = 1;
      time = {
        from = timeFrom;
        to = timeTo;
      };
    };
}
