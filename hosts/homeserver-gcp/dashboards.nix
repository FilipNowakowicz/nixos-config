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
    # Overview's fleet-comparison row supersedes the standalone Fleet board.
    fleet.enable = false;
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
            ds = dash.mimirDS;
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
                expr = ''count(ALERTS{alertstate="firing"}) or vector(0)'';
                legendFormat = "firing";
              })
            ];
          })
          (dash.statPanel {
            id = 2;
            title = "Failed Units";
            ds = dash.mimirDS;
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
            ds = dash.mimirDS;
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
            ds = dash.mimirDS;
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
            ds = dash.mimirDS;
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
            ds = dash.mimirDS;
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
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 4;
              w = 24;
              h = 6;
            };
            noValue = "No alerts firing — all clear";
            targets = [
              (dash.target {
                expr = ''ALERTS{alertstate="firing"}'';
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
          # ── Row 3: main machine detail ────────────────────────────────
          (dash.timeseriesPanel {
            id = 10;
            title = "CPU Usage % · main";
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 10;
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
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 12;
              y = 10;
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
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 18;
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
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 12;
              y = 18;
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
          # ── Row 4: fleet comparison (all hosts) ───────────────────────
          (dash.timeseriesPanel {
            id = 20;
            title = "CPU % by host";
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 26;
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
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 8;
              y = 26;
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
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 16;
              y = 26;
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
          # ── Row 5: backup & security posture ──────────────────────────
          (dash.statPanel {
            id = 30;
            title = "Backup Age (h)";
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 34;
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
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 5;
              y = 34;
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
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 10;
              y = 34;
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
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 15;
              y = 34;
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
            id = 34;
            title = "Vulnix Scan Age · gcp";
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 20;
              y = 34;
              w = 4;
              h = 5;
            };
            decimals = 0;
            colorMode = "none";
            graphMode = "none";
            unit = "h";
            thresholds = invThresholds 26 48;
            targets = [
              (dash.target {
                expr = "(time() - vulnix_scan_timestamp_seconds) / 3600";
                legendFormat = "age";
              })
            ];
          })
          # ── Row 6: logs ───────────────────────────────────────────────
          (dash.logsPanel {
            id = 40;
            title = "Journal Errors · main";
            ds = dash.lokiDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 39;
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
              y = 39;
              w = 12;
              h = 8;
            };
            targets = [
              (dash.target {
                expr = ''{job="audit-journal",audit_event_type="service_failure"}'';
              })
            ];
          })
        ];
      };
    };

    main-machine =
      let
        hostSel = dash.hostSelector "main";
      in
      {
        enable = true;
        definition = dash.mkDashboard {
          uid = "main-machine";
          title = "Main Machine";
          panels = [
            (dash.statPanel {
              id = 1;
              title = "CPU";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 0;
                y = 0;
                w = 6;
                h = 4;
              };
              unit = "percent";
              min = 0;
              max = 100;
              targets = [
                (dash.target {
                  expr = "100 - (avg(rate(node_cpu_seconds_total{${hostSel},mode=\"idle\"}[5m])) * 100)";
                  legendFormat = "CPU";
                })
              ];
            })
            (dash.statPanel {
              id = 2;
              title = "Memory";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 6;
                y = 0;
                w = 6;
                h = 4;
              };
              unit = "percent";
              min = 0;
              max = 100;
              targets = [
                (dash.target {
                  expr = "(1 - (node_memory_MemAvailable_bytes{${hostSel}} / node_memory_MemTotal_bytes{${hostSel}})) * 100";
                  legendFormat = "Memory";
                })
              ];
            })
            (dash.statPanel {
              id = 3;
              title = "Disk";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 12;
                y = 0;
                w = 6;
                h = 4;
              };
              unit = "percent";
              min = 0;
              max = 100;
              targets = [
                (dash.target {
                  expr = "max((node_filesystem_size_bytes{${hostSel},fstype!~\"tmpfs|efivarfs|overlay|squashfs|devtmpfs\"} - node_filesystem_avail_bytes{${hostSel},fstype!~\"tmpfs|efivarfs|overlay|squashfs|devtmpfs\"}) / node_filesystem_size_bytes{${hostSel},fstype!~\"tmpfs|efivarfs|overlay|squashfs|devtmpfs\"} * 100)";
                  legendFormat = "Max used";
                })
              ];
            })
            (dash.statPanel {
              id = 4;
              title = "Battery";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 18;
                y = 0;
                w = 6;
                h = 4;
              };
              unit = "percent";
              min = 0;
              max = 100;
              decimals = 0;
              # Battery is "higher is better": red only when actually low, not
              # the default red@90 that made a healthy battery glow red.
              thresholds = invThresholds 20 50;
              targets = [
                (dash.target {
                  expr = "node_power_supply_capacity{${hostSel},power_supply=\"BAT0\"}";
                  legendFormat = "BAT0";
                })
              ];
            })
            (dash.timeseriesPanel {
              id = 10;
              title = "Disk Usage %";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 0;
                y = 4;
                w = 12;
                h = 8;
              };
              unit = "percent";
              min = 0;
              max = 100;
              targets = [
                (dash.target {
                  expr = "(node_filesystem_size_bytes{${hostSel},fstype!~\"tmpfs|efivarfs|overlay|squashfs|devtmpfs\"} - node_filesystem_avail_bytes{${hostSel},fstype!~\"tmpfs|efivarfs|overlay|squashfs|devtmpfs\"}) / node_filesystem_size_bytes{${hostSel},fstype!~\"tmpfs|efivarfs|overlay|squashfs|devtmpfs\"} * 100";
                  legendFormat = "{{mountpoint}}";
                })
              ];
            })
            (dash.timeseriesPanel {
              id = 11;
              title = "CPU Usage %";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 12;
                y = 4;
                w = 12;
                h = 8;
              };
              unit = "percent";
              min = 0;
              max = 100;
              targets = [
                (dash.target {
                  expr = "100 - (avg(rate(node_cpu_seconds_total{${hostSel},mode=\"idle\"}[5m])) * 100)";
                  legendFormat = "CPU";
                })
              ];
            })
            (dash.timeseriesPanel {
              id = 12;
              title = "Memory Usage %";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 0;
                y = 12;
                w = 12;
                h = 8;
              };
              unit = "percent";
              min = 0;
              max = 100;
              targets = [
                (dash.target {
                  expr = "(1 - (node_memory_MemAvailable_bytes{${hostSel}} / node_memory_MemTotal_bytes{${hostSel}})) * 100";
                  legendFormat = "Memory";
                })
              ];
            })
            (dash.timeseriesPanel {
              id = 13;
              title = "Thermal Zones";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 12;
                y = 12;
                w = 12;
                h = 8;
              };
              unit = "celsius";
              targets = [
                (dash.target {
                  expr = "node_thermal_zone_temp{${hostSel}}";
                  legendFormat = "{{zone}}";
                })
              ];
            })
            (dash.timeseriesPanel {
              id = 15;
              title = "Failed Systemd Units";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 0;
                y = 20;
                w = 12;
                h = 8;
              };
              targets = [
                (dash.target {
                  expr = "node_systemd_unit_state{${hostSel},state=\"failed\"} == 1";
                  legendFormat = "{{unit}}";
                })
              ];
            })
            (dash.logsPanel {
              id = 16;
              title = "Kernel Errors";
              ds = dash.lokiDS;
              gridPos = dash.gridPos {
                x = 12;
                y = 20;
                w = 12;
                h = 8;
              };
              targets = [
                (dash.target {
                  expr = "{${hostSel},job=\"systemd-journal\"} |= \"kernel\" |~ \"(error|fail|oops|panic)\"";
                })
              ];
            })
            (dash.logsPanel {
              id = 17;
              title = "Systemd Journal Errors";
              ds = dash.lokiDS;
              gridPos = dash.gridPos {
                x = 0;
                y = 28;
                w = 24;
                h = 8;
              };
              targets = [
                (dash.target {
                  expr = "{${hostSel},job=\"systemd-journal\"} |= \"Failed\"";
                })
              ];
            })
          ];
        };
      };
  };
}
