_:
let
  dash = import ../../lib/dashboards.nix;
in
{
  profiles.observability.dashboards = {
    fleet.enable = true;
    security-events.enable = true;

    lynis = {
      enable = true;
      definition = dash.mkDashboard {
        uid = "homeserver-lynis";
        title = "Security Audit";
        panels = [
          (dash.timeseriesPanel {
            id = 1;
            title = "Hardening Index (0-100)";
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 0;
              w = 12;
              h = 8;
            };
            targets = [
              (dash.target {
                expr = "lynis_hardening_index";
                legendFormat = "hardening index";
              })
            ];
          })
          (dash.timeseriesPanel {
            id = 2;
            title = "Warnings";
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 12;
              y = 0;
              w = 12;
              h = 8;
            };
            targets = [
              (dash.target {
                expr = "lynis_warnings_total";
                legendFormat = "warnings";
              })
            ];
          })
          (dash.timeseriesPanel {
            id = 3;
            title = "Audit Age (hours)";
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 8;
              w = 12;
              h = 8;
            };
            targets = [
              (dash.target {
                expr = "(time() - lynis_scan_timestamp_seconds) / 3600";
                legendFormat = "hours since last audit";
              })
            ];
          })
        ];
      };
    };

    cve = {
      enable = true;
      definition = dash.mkDashboard {
        uid = "homeserver-cve";
        title = "CVE Scan";
        panels = [
          (dash.timeseriesPanel {
            id = 1;
            title = "CVE Findings (after whitelist)";
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 0;
              w = 12;
              h = 8;
            };
            targets = [
              (dash.target {
                expr = "vulnix_cve_total";
                legendFormat = "CVEs";
              })
            ];
          })
          (dash.timeseriesPanel {
            id = 2;
            title = "Affected Packages (after whitelist)";
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 12;
              y = 0;
              w = 12;
              h = 8;
            };
            targets = [
              (dash.target {
                expr = "vulnix_affected_packages_total";
                legendFormat = "packages";
              })
            ];
          })
          (dash.timeseriesPanel {
            id = 3;
            title = "Scan Age (hours)";
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 8;
              w = 12;
              h = 8;
            };
            targets = [
              (dash.target {
                expr = "(time() - vulnix_scan_timestamp_seconds) / 3600";
                legendFormat = "hours since last scan";
              })
            ];
          })
        ];
      };
    };

    backup = {
      enable = true;
      definition = dash.mkDashboard {
        uid = "homeserver-backup-health";
        title = "Backup Health";
        panels = [
          (dash.timeseriesPanel {
            id = 1;
            title = "Backup Age (hours)";
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 0;
              y = 0;
              w = 12;
              h = 8;
            };
            targets = [
              (dash.target {
                expr = "(time() - restic_last_backup_timestamp_seconds) / 3600";
                legendFormat = "hours since last backup";
              })
            ];
          })
          (dash.timeseriesPanel {
            id = 2;
            title = "Check Age (hours)";
            ds = dash.mimirDS;
            gridPos = dash.gridPos {
              x = 12;
              y = 0;
              w = 12;
              h = 8;
            };
            targets = [
              (dash.target {
                expr = "(time() - restic_last_check_timestamp_seconds) / 3600";
                legendFormat = "hours since last check";
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
            (dash.timeseriesPanel {
              id = 10;
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
                  expr = "(node_filesystem_size_bytes{${hostSel},fstype!~\"tmpfs|efivarfs|overlay|squashfs|devtmpfs\"} - node_filesystem_avail_bytes{${hostSel},fstype!~\"tmpfs|efivarfs|overlay|squashfs|devtmpfs\"}) / node_filesystem_size_bytes{${hostSel},fstype!~\"tmpfs|efivarfs|overlay|squashfs|devtmpfs\"} * 100";
                  legendFormat = "{{device}}";
                })
              ];
            })
            (dash.timeseriesPanel {
              id = 11;
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
                y = 8;
                w = 8;
                h = 8;
              };
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
                x = 8;
                y = 8;
                w = 8;
                h = 8;
              };
              targets = [
                (dash.target {
                  expr = "node_thermal_zone_temp{${hostSel}}";
                  legendFormat = "{{zone}}";
                })
              ];
            })
            (dash.timeseriesPanel {
              id = 14;
              title = "Battery %";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 16;
                y = 8;
                w = 8;
                h = 8;
              };
              targets = [
                (dash.target {
                  expr = "node_power_supply_capacity{${hostSel}}";
                  legendFormat = "{{power_supply}}";
                })
              ];
            })
            (dash.timeseriesPanel {
              id = 15;
              title = "Failed Systemd Units";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 0;
                y = 16;
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
                y = 16;
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
                y = 24;
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
