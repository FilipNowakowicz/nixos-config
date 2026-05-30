# Mimir ruler alert rules and minimal Alertmanager config.
# Rules are provisioned declaratively via systemd-tmpfiles (C+ copy from nix store).
# Mimir's ruler polls ruler_storage for changes; rules take effect after the next
# poll cycle without a restart.
#
# Thresholds:
#   DiskUsageHigh     — filesystem > 80% for 5 min (excludes tmpfs/overlay/squashfs)
#   SystemdUnitFailed — any unit in failed state for > 2 min
#   ResticBackupStale — backup older than 26 h (daily + 2 h buffer)
#   ResticCheckStale  — integrity check older than 8 d (weekly + 1 d buffer)
#   VulnixCveFound    — any CVE finding after whitelist (add known-acceptable CVEs to vulnix-whitelist.toml)
#   VulnixScanStale   — no successful scan in 26 h (daily + 2 h buffer)
#   LynisScoreLow     — hardening index < 60 for 0 m
#   LynisScanStale    — no successful audit in 26 h (daily + 2 h buffer)
#   BlackboxProbeFailed — blackbox HTTP probe failing for 5 min
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.profiles.observability;
  mkYaml = name: data: (pkgs.formats.yaml { }).generate name data;

  rulesFile = mkYaml "infrastructure-alerts.yaml" {
    groups = [
      {
        name = "infrastructure";
        interval = "1m";
        rules = [
          {
            alert = "DiskUsageHigh";
            expr = ''(1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|efivarfs|squashfs|devtmpfs"} / node_filesystem_size_bytes) * 100 > 80'';
            for = "5m";
            labels.severity = "warning";
            annotations = {
              summary = "High disk usage on {{ $labels.instance }}";
              description = "{{ $labels.mountpoint }} on {{ $labels.instance }} is {{ $value | printf \"%.1f\" }}% full (threshold: 80%).";
            };
          }
          {
            alert = "SystemdUnitFailed";
            expr = ''node_systemd_unit_state{state="failed"} > 0'';
            for = "2m";
            labels.severity = "critical";
            annotations = {
              summary = "Systemd unit failed on {{ $labels.instance }}";
              description = "Unit {{ $labels.name }} has been in a failed state for >2 minutes.";
            };
          }
          {
            alert = "ResticBackupStale";
            expr = "(time() - restic_last_backup_timestamp_seconds) / 3600 > 26";
            for = "0m";
            labels.severity = "critical";
            annotations = {
              summary = "Restic backup stale on {{ $labels.instance }}";
              description = "Last backup {{ $value | printf \"%.1f\" }}h ago (threshold: 26h).";
            };
          }
          {
            alert = "ResticCheckStale";
            expr = "(time() - restic_last_check_timestamp_seconds) / 86400 > 8";
            for = "0m";
            labels.severity = "warning";
            annotations = {
              summary = "Restic integrity check stale on {{ $labels.instance }}";
              description = "Last check {{ $value | printf \"%.1f\" }}d ago (threshold: 8d).";
            };
          }
          {
            alert = "LynisScoreLow";
            expr = "lynis_hardening_index < 60";
            for = "0m";
            labels.severity = "warning";
            annotations = {
              summary = "Lynis hardening score low on {{ $labels.instance }}";
              description = "Hardening index is {{ $value }} (threshold: 60). Review lynis warnings and suggestions.";
            };
          }
          {
            alert = "LynisScanStale";
            expr = "(time() - lynis_scan_timestamp_seconds) / 3600 > 26";
            for = "0m";
            labels.severity = "warning";
            annotations = {
              summary = "Lynis audit stale on {{ $labels.instance }}";
              description = "Last audit {{ $value | printf \"%.1f\" }}h ago (threshold: 26h). Check lynis-audit.service logs.";
            };
          }
          {
            alert = "VulnixCveFound";
            expr = "vulnix_cve_total > 0";
            for = "0m";
            labels.severity = "critical";
            annotations = {
              summary = "CVE findings on {{ $labels.instance }}";
              description = "{{ $value }} CVE(s) found in current system closure. Review and suppress known-acceptable findings in vulnix-whitelist.toml.";
            };
          }
          {
            alert = "VulnixScanStale";
            expr = "(time() - vulnix_scan_timestamp_seconds) / 3600 > 26";
            for = "0m";
            labels.severity = "warning";
            annotations = {
              summary = "Vulnix scan stale on {{ $labels.instance }}";
              description = "Last CVE scan {{ $value | printf \"%.1f\" }}h ago (threshold: 26h). Check vulnix-scan.service logs.";
            };
          }
          {
            alert = "BlackboxProbeFailed";
            expr = ''probe_success{job=~"blackbox-.*"} == 0'';
            for = "5m";
            labels.severity = "critical";
            annotations = {
              summary = "Blackbox probe failed for {{ $labels.probe }}";
              description = "Synthetic check to {{ $labels.instance }} has failed for more than 5 minutes. Review nginx routing, TLS, auth boundary, and upstream service health.";
            };
          }
        ];
      }
    ];
  };

  # Alertmanager config. When `alertWebhookUrl` is set, alerts are routed to a
  # webhook receiver (ntfy.sh format: POST the alert JSON to the URL). Otherwise
  # they route to a null receiver so the ruler has somewhere to send alerts
  # without erroring. Override further in host config via lib.mkForce if needed.
  webhookEnabled = cfg.alertWebhookUrl != "";
  alertmanagerFile = mkYaml "alertmanager.yaml" {
    route = {
      receiver = if webhookEnabled then "webhook" else "null";
      group_by = [
        "alertname"
        "instance"
      ];
      group_wait = "30s";
      group_interval = "5m";
      repeat_interval = "4h";
    };
    receivers =
      [ { name = "null"; } ]
      ++ lib.optional webhookEnabled {
        name = "webhook";
        webhook_configs = [
          {
            url = cfg.alertWebhookUrl;
            send_resolved = true;
          }
        ];
      };
  };
in
{
  config = lib.mkIf (cfg.enable && cfg.mimir.enable) {
    services.mimir.configuration.ruler = {
      alertmanager_url = "http://127.0.0.1:9009/alertmanager";
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/mimir/rules/anonymous 0750 mimir mimir -"
      "d /var/lib/mimir/alertmanager/anonymous 0750 mimir mimir -"
      "C+ /var/lib/mimir/rules/anonymous/infrastructure-alerts.yaml 0640 mimir mimir - ${rulesFile}"
      "C+ /var/lib/mimir/alertmanager/anonymous/alertmanager.yaml 0640 mimir mimir - ${alertmanagerFile}"
    ];
  };
}
