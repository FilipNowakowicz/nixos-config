# Shared source of truth for the Prometheus evaluator alert rules and the minimal
# Alertmanager config. Imported by both the observability module
# (modules/nixos/profiles/observability/alerts.nix) and the
# observability-alerts-lint flake check so the two cannot drift.
#
# Thresholds:
#   DiskUsageHigh     — filesystem > 80% for 5 min (excludes tmpfs/overlay/squashfs)
#   SystemdUnitFailed — any unit in failed state for > 2 min
#   ResticBackupStale — backup older than 26 h (daily + 2 h buffer)
#   ResticCheckStale  — integrity check older than 8 d (weekly + 1 d buffer)
#   ResticRestoreCanaryStale — restore canary older than 2 d
#   RestoreDrillStale — full-service restore drill older than ~100 d (quarterly + buffer)
#   HeartbeatPingStale — external heartbeat ping older than 15 min
#
# Note: CVE scanning is intentionally CI-only. vulnix loads the full NVD dataset
# (~3 GB RSS) which OOMs the 3.8 GB homeserver-gcp host; the authoritative,
# gating CVE signal is the scheduled `.github/workflows/cve-scan.yml` run
# (`scripts/validate.sh cve-reports`), which scans the flake-built closures with
# real advisories + severity. No live-host vulnix scan or freshness alert exists.
#   LynisScoreLow     — hardening index < 70 for 0 m (healthy baseline is 77)
#   LynisScanStale    — no successful audit in 26 h (daily + 2 h buffer)
#   BlackboxProbeFailed — blackbox HTTP probe failing for 5 min
#   DnsProbeFailed    — blackbox DNS probe (AdGuard) failing for 5 min
#   ScrapeTargetDown  — a scrape target (incl. the stack's own components)
#                       answering no scrape for 5 min
#   TLSCertificateExpiresSoon — HTTPS certificate expires within 7 d
#   BackupEvidenceMissing — a host is reporting but has no success timestamp
#                           for a backup job it is expected to run, for 1 h
#   GcpBuilderLeftRunning — gcp-builder online in the tailnet for 4 h
#   Watchdog          — always firing; Alertmanager posts it to an external
#                       dead-man's-switch, which alerts when the posts stop
let
  evidence = import ./backup-evidence.nix;
  inherit (evidence) metrics;
  hostRegistry = import ./hosts.nix;

  # Renaming the builder in the registry fails here, not as a silent rule.
  builderName =
    assert hostRegistry ? gcp-builder;
    "gcp-builder";

  # The *Stale rules above compare the age of an existing series, so they
  # cannot fire for a job that never succeeded or whose textfile was removed.
  # Every active host with a registry `backup` entry reports to this
  # Prometheus and is expected to have the timestamps that entry declares
  # (lib/backup-evidence.nix). main's stamps sit on a persisted path
  # (hosts/main/impermanence.nix), so a reboot does not empty its series.
  expectedBackupEvidence = builtins.mapAttrs (_: evidence.expectedFor) (
    builtins.removeAttrs hostRegistry (
      builtins.filter (
        name: hostRegistry.${name}.status != "active" || !(hostRegistry.${name} ? backup)
      ) (builtins.attrNames hostRegistry)
    )
  );

  # One series per missing (host, metric), labelled with the metric name.
  missingEvidenceExpr = builtins.concatStringsSep "\nor\n" (
    builtins.concatLists (
      map (
        host:
        map (
          metric:
          ''label_replace(group by (host) (node_boot_time_seconds{host="${host}"}) unless on (host) group by (host) (${metric}{host="${host}"}), "metric", "${metric}", "", "")''
        ) expectedBackupEvidence.${host}
      ) (builtins.attrNames expectedBackupEvidence)
    )
  );
in
{
  inherit expectedBackupEvidence;

  rules = {
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
            expr = "(time() - ${metrics.backup}) / 3600 > 26";
            for = "0m";
            labels.severity = "critical";
            annotations = {
              summary = "Restic backup stale on {{ $labels.instance }}";
              description = "Last backup {{ $value | printf \"%.1f\" }}h ago (threshold: 26h).";
            };
          }
          {
            alert = "ResticCheckStale";
            expr = "(time() - ${metrics.check}) / 86400 > 8";
            for = "0m";
            labels.severity = "warning";
            annotations = {
              summary = "Restic integrity check stale on {{ $labels.instance }}";
              description = "Last check {{ $value | printf \"%.1f\" }}d ago (threshold: 8d).";
            };
          }
          {
            alert = "BackupEvidenceMissing";
            expr = missingEvidenceExpr;
            for = "1h";
            labels.severity = "warning";
            annotations = {
              summary = "No {{ $labels.metric }} on {{ $labels.host }}";
              description = "{{ $labels.host }} is reporting metrics but has no {{ $labels.metric }} series, so the matching stale alert cannot fire. The job has never succeeded or its textfile was removed.";
            };
          }
          {
            alert = "ResticRestoreCanaryStale";
            expr = "(time() - ${metrics.restoreTest}) / 3600 > 50";
            for = "30m";
            labels.severity = "warning";
            annotations = {
              summary = "Restic restore canary stale on {{ $labels.instance }}";
              description = "No successful restore canary has been recorded for more than 50 hours.";
            };
          }
          {
            # Full-service restore drill runs quarterly; alert if no successful
            # full-service bring-up has been recorded in ~100 days (one quarter
            # plus a generous buffer for a single skipped/failed run).
            alert = "RestoreDrillStale";
            expr = "(time() - ${metrics.restoreDrill}) / 86400 > 100";
            for = "1h";
            labels.severity = "warning";
            annotations = {
              summary = "Full-service restore drill stale on {{ $labels.instance }}";
              description = "No successful full-service restore drill (Grafana + AdGuard Home brought up from B2) in more than 100 days. Check restore-drill-b2.service.";
            };
          }
          {
            alert = "HeartbeatPingStale";
            expr = "(time() - heartbeat_last_ping_timestamp_seconds) / 60 > 15";
            for = "0m";
            labels.severity = "warning";
            annotations = {
              summary = "Heartbeat ping stale on {{ $labels.instance }}";
              description = "No successful external heartbeat ping has been recorded for more than 15 minutes.";
            };
          }
          {
            # The healthy index is 77. 70 flags a real hardening regression,
            # and a broken audit: without its tool PATH the index under-reports
            # at ~58, and a report without an index is written as 0.
            alert = "LynisScoreLow";
            expr = "lynis_hardening_index < 70";
            for = "0m";
            labels.severity = "warning";
            annotations = {
              summary = "Lynis hardening score low on {{ $labels.instance }}";
              description = "Hardening index is {{ $value }} (threshold: 70, healthy baseline 77). Review lynis warnings and suggestions, and the audit's tool PATH.";
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
            alert = "BlackboxProbeFailed";
            expr = ''probe_success{job=~"blackbox-.*"} == 0'';
            for = "5m";
            labels.severity = "critical";
            annotations = {
              summary = "Blackbox probe failed for {{ $labels.probe }}";
              description = "Synthetic check to {{ $labels.instance }} has failed for more than 5 minutes. Review nginx routing, TLS, auth boundary, and upstream service health.";
            };
          }
          {
            alert = "TLSCertificateExpiresSoon";
            expr = ''probe_ssl_earliest_cert_expiry{job=~"blackbox-.*"} - time() < 7 * 24 * 3600'';
            for = "0m";
            labels.severity = "warning";
            annotations = {
              summary = "TLS certificate expires soon for {{ $labels.instance }}";
              description = "The earliest certificate in the probed TLS chain expires in less than 7 days. Check tailscale-cert.service and nginx reload status.";
            };
          }
          {
            # AdGuard is the tailnet-wide resolver. A hung AdGuard or failing
            # upstreams leave its unit active, so only a real lookup shows it.
            alert = "DnsProbeFailed";
            expr = ''probe_success{job=~"dns-.*"} == 0'';
            for = "5m";
            labels.severity = "critical";
            annotations = {
              summary = "DNS probe failed for {{ $labels.probe }}";
              description = "Resolving a real external name through {{ $labels.instance }} has failed for more than 5 minutes, so tailnet DNS is likely broken for every client. Check adguardhome.service and its upstreams; the fallback is removing the Tailscale DNS nameserver override.";
            };
          }
          {
            alert = "ScrapeTargetDown";
            expr = "up == 0";
            for = "5m";
            labels.severity = "warning";
            annotations = {
              summary = "Scrape target {{ $labels.job }} down on {{ $labels.host }}";
              description = "Prometheus has failed to scrape {{ $labels.job }} at {{ $labels.instance }} for more than 5 minutes. The component may be hung even though its unit is still active.";
            };
          }
          {
            # The source is homeserver-gcp's own tailnet view (tailscale
            # status), written by hosts/homeserver-gcp/tailnet-presence.nix.
            # `for` state survives a Prometheus restart (ALERTS_FOR_STATE).
            alert = "GcpBuilderLeftRunning";
            expr = ''tailscale_peer_online{peer="${builderName}"} == 1'';
            for = "4h";
            labels.severity = "warning";
            annotations = {
              summary = "${builderName} has been running for over 4 hours";
              description = "${builderName} has been online in the tailnet for more than 4 hours. Its idle shutdown may be broken: check builder-idle-shutdown on it, and unless an on-worker job is still running, stop the instance from GCP.";
            };
          }
        ];
      }
      {
        name = "alerting-pipeline";
        interval = "1m";
        rules = [
          {
            # Always firing. Alertmanager routes it to an external
            # dead-man's-switch every minute, so a broken evaluator,
            # Alertmanager or notification path is noticed off-host.
            alert = "Watchdog";
            expr = "vector(1)";
            labels.severity = "none";
            annotations = {
              summary = "Alerting pipeline heartbeat";
              description = "Always firing by design. It proves the Prometheus to Alertmanager to webhook path works; the external check alerts when it stops arriving.";
            };
          }
        ];
      }
    ];
  };

  # Minimal Alertmanager config — null receiver so the ruler has somewhere to
  # send alerts without erroring. modules/nixos/profiles/observability/alerts.nix
  # swaps in the webhook and watchdog receivers when their URL files are set.
  alertmanager = {
    route = {
      receiver = "null";
      group_by = [
        "alertname"
        "instance"
      ];
      group_wait = "30s";
      group_interval = "5m";
      repeat_interval = "4h";
    };
    # Watchdog never reaches the normal receiver. A short repeat keeps the
    # external check pinged about every minute or two.
    watchdogRoute = {
      matchers = [ ''alertname="Watchdog"'' ];
      receiver = "null";
      group_wait = "0s";
      group_interval = "1m";
      repeat_interval = "1m";
      continue = false;
    };
    receivers = [ { name = "null"; } ];
  };
}
