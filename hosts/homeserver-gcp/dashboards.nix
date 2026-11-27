_:
let
  dash = import ../../lib/dashboards.nix;
  notVirt = ''fstype!~"tmpfs|efivarfs|overlay|squashfs|devtmpfs"'';
  # inverted "higher is better" threshold steps (red low → green high)
  invThresholds = orange: green: [
    {
      color = "red";
      value = null;
    }
    {
      color = "orange";
      value = orange;
    }
    {
      color = "green";
      value = green;
    }
  ];
  # "zero is good, anything is bad" count tile
  countThresholds = [
    {
      color = "green";
      value = null;
    }
    {
      color = "red";
      value = 1;
    }
  ];
  # ascending "lower is better" age tile
  ageThresholds = orange: red: [
    {
      color = "green";
      value = null;
    }
    {
      color = "orange";
      value = orange;
    }
    {
      color = "red";
      value = red;
    }
  ];
in
{
  profiles.observability.dashboards = {
    security-events.enable = true;

    overview = {
      enable = true;
      definition = dash.mkDashboard {
        uid = "overview";
        title = "Overview";
        timeFrom = "now-3h";
        panels = [
          # ── Row 1: at-a-glance KPI tiles ──────────────────────────────
          (dash.statPanel {
            id = 1;
            title = "Firing Alerts";
            ds = dash.prometheusDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 0;
              w = 4;
              h = 4;
            };
            decimals = 0;
            colorMode = "background";
            graphMode = "none";
            thresholds = countThresholds;
            targets = [
              (dash.target {
                expr = ''count(ALERTS{alertstate="firing",alertname!="Watchdog"}) or vector(0)'';
                legendFormat = "firing";
              })
            ];
          })
          (dash.statPanel {
            id = 2;
            title = "Failed Units";
            ds = dash.prometheusDS;
            gridPos = dash.gridPos {
              x = 4;
              y = 0;
              w = 4;
              h = 4;
            };
            decimals = 0;
            colorMode = "background";
            graphMode = "none";
            thresholds = countThresholds;
            targets = [
              (dash.target {
                expr = ''sum(node_systemd_unit_state{state="failed"}) or vector(0)'';
                legendFormat = "failed";
              })
            ];
          })
          (dash.statPanel {
            id = 3;
            title = "CPU · main";
            ds = dash.prometheusDS;
            gridPos = dash.gridPos {
              x = 8;
              y = 0;
              w = 4;
              h = 4;
            };
            unit = "percent";
            min = 0;
            max = 100;
            targets = [
              (dash.target {
                expr = ''100 - (avg(rate(node_cpu_seconds_total{host="main",mode="idle"}[5m])) * 100)'';
                legendFormat = "CPU";
              })
            ];
          })
          (dash.statPanel {
            id = 4;
            title = "Memory · main";
            ds = dash.prometheusDS;
            gridPos = dash.gridPos {
              x = 12;
              y = 0;
              w = 4;
              h = 4;
            };
            unit = "percent";
            min = 0;
            max = 100;
            targets = [
              (dash.target {
                expr = ''(1 - (node_memory_MemAvailable_bytes{host="main"} / node_memory_MemTotal_bytes{host="main"})) * 100'';
                legendFormat = "Memory";
              })
            ];
          })
          (dash.statPanel {
            id = 5;
            title = "Disk · main";
            ds = dash.prometheusDS;
            gridPos = dash.gridPos {
              x = 16;
              y = 0;
              w = 4;
              h = 4;
            };
            unit = "percent";
            min = 0;
            max = 100;
            targets = [
              (dash.target {
                expr = ''max((node_filesystem_size_bytes{host="main",${notVirt}} - node_filesystem_avail_bytes{host="main",${notVirt}}) / node_filesystem_size_bytes{host="main",${notVirt}} * 100)'';
                legendFormat = "Max used";
              })
            ];
          })
          (dash.statPanel {
            id = 6;
            title = "Battery · main";
            ds = dash.prometheusDS;
            gridPos = dash.gridPos {
              x = 20;
              y = 0;
              w = 4;
              h = 4;
            };
            unit = "percent";
            min = 0;
            max = 100;
            decimals = 0;
            thresholds = invThresholds 20 50;
            targets = [
              (dash.target {
                expr = ''node_power_supply_capacity{host="main",power_supply="BAT0"}'';
                legendFormat = "BAT0";
              })
            ];
          })
          # ── Row 2: what is broken right now ───────────────────────────
          (dash.tablePanel {
            id = 7;
            title = "Firing Alerts";
            ds = dash.prometheusDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 4;
              w = 24;
              h = 6;
            };
            noValue = "No alerts firing — all clear";
            targets = [
              (dash.target {
                expr = ''ALERTS{alertstate="firing",alertname!="Watchdog"}'';
                format = "table";
                instant = true;
              })
            ];
            transformations = [
              {
                id = "organize";
                options = {
                  excludeByName = {
                    Time = true;
                    Value = true;
                    "Value #A" = true;
                    __name__ = true;
                    alertstate = true;
                    instance = true;
                    job = true;
                  };
                  renameByName = {
                    alertname = "Alert";
                    severity = "Severity";
                    host = "Host";
                  };
                  indexByName = {
                    alertname = 0;
                    severity = 1;
                    host = 2;
                  };
                };
              }
            ];
            overrides = [
              {
                matcher = {
                  id = "byName";
                  options = "Severity";
                };
                properties = [
                  {
                    id = "custom.cellOptions";
                    value.type = "color-text";
                  }
                  {
                    id = "mappings";
                    value = [
                      {
                        type = "value";
                        options = {
                          critical = {
                            color = "red";
                            index = 0;
                          };
                          warning = {
                            color = "orange";
                            index = 1;
                          };
                        };
                      }
                    ];
                  }
                ];
              }
            ];
          })
          # ── Row 3: fleet comparison (all hosts) ───────────────────────
          (dash.timeseriesPanel {
            id = 20;
            title = "CPU % by host";
            ds = dash.prometheusDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 10;
              w = 8;
              h = 8;
            };
            unit = "percent";
            min = 0;
            max = 100;
            targets = [
              (dash.target {
                expr = ''100 - (avg by(host) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'';
                legendFormat = "{{host}}";
              })
            ];
          })
          (dash.timeseriesPanel {
            id = 21;
            title = "Memory % by host";
            ds = dash.prometheusDS;
            gridPos = dash.gridPos {
              x = 8;
              y = 10;
              w = 8;
              h = 8;
            };
            unit = "percent";
            min = 0;
            max = 100;
            targets = [
              (dash.target {
                expr = "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100";
                legendFormat = "{{host}}";
              })
            ];
          })
          (dash.timeseriesPanel {
            id = 22;
            title = "Root Disk % by host";
            ds = dash.prometheusDS;
            gridPos = dash.gridPos {
              x = 16;
              y = 10;
              w = 8;
              h = 8;
            };
            unit = "percent";
            min = 0;
            max = 100;
            targets = [
              (dash.target {
                expr = ''(1 - node_filesystem_avail_bytes{${notVirt},mountpoint="/"} / node_filesystem_size_bytes) * 100'';
                legendFormat = "{{host}}";
              })
            ];
          })
          # ── Row 4: backup & security posture ──────────────────────────
          (dash.statPanel {
            id = 30;
            title = "Backup Age (h)";
            ds = dash.prometheusDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 18;
              w = 5;
              h = 5;
            };
            unit = "h";
            decimals = 1;
            graphMode = "none";
            thresholds = ageThresholds 20 26;
            targets = [
              (dash.target {
                expr = "(time() - restic_last_backup_timestamp_seconds) / 3600";
                legendFormat = "{{host}}";
              })
            ];
          })
          (dash.statPanel {
            id = 31;
            title = "Check Age (d) · gcp";
            ds = dash.prometheusDS;
            gridPos = dash.gridPos {
              x = 5;
              y = 18;
              w = 5;
              h = 5;
            };
            unit = "d";
            decimals = 1;
            graphMode = "none";
            thresholds = ageThresholds 7 8;
            targets = [
              (dash.target {
                expr = "(time() - restic_last_check_timestamp_seconds) / 86400";
                legendFormat = "check";
              })
            ];
          })
          (dash.statPanel {
            id = 32;
            title = "Lynis Index · gcp";
            ds = dash.prometheusDS;
            gridPos = dash.gridPos {
              x = 10;
              y = 18;
              w = 5;
              h = 5;
            };
            min = 0;
            max = 100;
            decimals = 0;
            graphMode = "none";
            thresholds = invThresholds 60 70;
            targets = [
              (dash.target {
                expr = "lynis_hardening_index";
                legendFormat = "index";
              })
            ];
          })
          (dash.statPanel {
            id = 33;
            title = "TLS Cert (d)";
            ds = dash.prometheusDS;
            gridPos = dash.gridPos {
              x = 15;
              y = 18;
              w = 5;
              h = 5;
            };
            unit = "d";
            decimals = 0;
            graphMode = "none";
            thresholds = invThresholds 14 30;
            targets = [
              (dash.target {
                expr = "min((probe_ssl_earliest_cert_expiry - time()) / 86400)";
                legendFormat = "expiry";
              })
            ];
          })
          (dash.statPanel {
            id = 35;
            title = "Restore Drill Age (d) · gcp";
            ds = dash.prometheusDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 23;
              w = 5;
              h = 5;
            };
            unit = "d";
            decimals = 1;
            graphMode = "none";
            # Quarterly drill: green well within a quarter, orange as it ages,
            # red past the ~100d RestoreDrillStale threshold.
            thresholds = ageThresholds 95 100;
            targets = [
              (dash.target {
                expr = "(time() - restore_drill_last_success_timestamp_seconds) / 86400";
                legendFormat = "drill";
              })
            ];
          })
          # ── Row 5: logs ───────────────────────────────────────────────
          (dash.logsPanel {
            id = 40;
            title = "Journal Errors · main";
            ds = dash.lokiDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 28;
              w = 12;
              h = 8;
            };
            targets = [
              (dash.target {
                expr = ''{host="main",job="systemd-journal"} |= "Failed"'';
              })
            ];
          })
          (dash.logsPanel {
            id = 41;
            title = "Service Failures · fleet";
            ds = dash.lokiDS;
            gridPos = dash.gridPos {
              x = 12;
              y = 28;
              w = 12;
              h = 8;
            };
            targets = [
              (dash.target {
                expr = ''{job="audit-journal",audit_event_type="service_failure"}'';
              })
            ];
          })
          # ── Row 6: main machine detail, collapsed ─────────────────────
          # Kept last: an expanded Grafana row owns every top-level panel
          # below it, so a collapsed row above ungrouped panels would absorb
          # them the first time it is toggled.
          (dash.rowPanel {
            id = 50;
            title = "main";
            y = 36;
            panels = [
              (dash.timeseriesPanel {
                id = 10;
                title = "CPU Usage % · main";
                ds = dash.prometheusDS;
                gridPos = dash.gridPos {
                  x = 0;
                  y = 37;
                  w = 12;
                  h = 8;
                };
                unit = "percent";
                min = 0;
                max = 100;
                targets = [
                  (dash.target {
                    expr = ''100 - (avg(rate(node_cpu_seconds_total{host="main",mode="idle"}[5m])) * 100)'';
                    legendFormat = "CPU";
                  })
                ];
              })
              (dash.timeseriesPanel {
                id = 11;
                title = "Memory Usage % · main";
                ds = dash.prometheusDS;
                gridPos = dash.gridPos {
                  x = 12;
                  y = 37;
                  w = 12;
                  h = 8;
                };
                unit = "percent";
                min = 0;
                max = 100;
                targets = [
                  (dash.target {
                    expr = ''(1 - (node_memory_MemAvailable_bytes{host="main"} / node_memory_MemTotal_bytes{host="main"})) * 100'';
                    legendFormat = "Memory";
                  })
                ];
              })
              (dash.timeseriesPanel {
                id = 12;
                title = "Disk Usage % by mount · main";
                ds = dash.prometheusDS;
                gridPos = dash.gridPos {
                  x = 0;
                  y = 45;
                  w = 12;
                  h = 8;
                };
                unit = "percent";
                min = 0;
                max = 100;
                targets = [
                  (dash.target {
                    expr = ''(node_filesystem_size_bytes{host="main",${notVirt}} - node_filesystem_avail_bytes{host="main",${notVirt}}) / node_filesystem_size_bytes{host="main",${notVirt}} * 100'';
                    legendFormat = "{{mountpoint}}";
                  })
                ];
              })
              (dash.timeseriesPanel {
                id = 13;
                title = "Thermal Zones · main";
                ds = dash.prometheusDS;
                gridPos = dash.gridPos {
                  x = 12;
                  y = 45;
                  w = 12;
                  h = 8;
                };
                unit = "celsius";
                targets = [
                  (dash.target {
                    expr = ''node_thermal_zone_temp{host="main"}'';
                    legendFormat = "{{zone}}";
                  })
                ];
              })
              (dash.timeseriesPanel {
                id = 14;
                title = "Failed Systemd Units · main";
                ds = dash.prometheusDS;
                gridPos = dash.gridPos {
                  x = 0;
                  y = 53;
                  w = 12;
                  h = 8;
                };
                targets = [
                  (dash.target {
                    expr = ''node_systemd_unit_state{host="main",state="failed"} == 1'';
                    legendFormat = "{{unit}}";
                  })
                ];
              })
              (dash.logsPanel {
                id = 15;
                title = "Kernel Errors · main";
                ds = dash.lokiDS;
                gridPos = dash.gridPos {
                  x = 12;
                  y = 53;
                  w = 12;
                  h = 8;
                };
                targets = [
                  (dash.target {
                    expr = ''{host="main",job="systemd-journal"} |= "kernel" |~ "(error|fail|oops|panic)"'';
                  })
                ];
              })
            ];
          })
        ];
      };
    };
  };
}
