_:
let
  dash = import ../../lib/dashboards.nix;
in
{
  profiles.observability.dashboards = {
    fleet.enable = true;

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
  };
}
