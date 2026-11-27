# Lint the shared alert rules and evaluate the observability modules as a
# downstream flake would import them.
{
  lib,
  pkgs,
  self,
  ...
}:
let
  # Lint the Prometheus alert rules with promtool. Renders the exact same
  # shared data the observability module deploys (lib/observability-alerts.nix)
  # so a typo in a metric name, label, or expr fails the light lane instead of
  # silently shipping a non-firing rule.
  alertData = import ../../lib/observability-alerts.nix;
  rulesYaml = (pkgs.formats.yaml { }).generate "infrastructure-alerts.yaml" alertData.rules;
  requiredAlerts = [
    "SystemdUnitFailed"
    "ResticBackupStale"
    "ResticCheckStale"
    "ResticRestoreCanaryStale"
    "HeartbeatPingStale"
    "BlackboxProbeFailed"
    "TLSCertificateExpiresSoon"
    "BackupEvidenceMissing"
  ];

  # promtool unit tests for BackupEvidenceMissing: a reporting host missing
  # one expected timestamp alerts after the hold, the others stay quiet, and
  # a host that is not reporting at all (e.g. powered off) never alerts.
  # One case per host in expectedBackupEvidence.
  missingEvidenceTests =
    let
      hostCase =
        host:
        let
          expected = alertData.expectedBackupEvidence.${host};
          missing = lib.last expected;
          series = name: {
            series = ''${name}{host="${host}",instance="127.0.0.1:9100",job="node"}'';
            values = "1x150";
          };
        in
        {
          interval = "1m";
          input_series = map series ([ "node_boot_time_seconds" ] ++ lib.init expected);
          alert_rule_test = [
            {
              eval_time = "30m";
              alertname = "BackupEvidenceMissing";
              exp_alerts = [ ];
            }
            {
              eval_time = "90m";
              alertname = "BackupEvidenceMissing";
              exp_alerts = [
                {
                  exp_labels = {
                    severity = "warning";
                    inherit host;
                    metric = missing;
                  };
                  exp_annotations = {
                    summary = "No ${missing} on ${host}";
                    description = "${host} is reporting metrics but has no ${missing} series, so the matching stale alert cannot fire. The job has never succeeded or its textfile was removed.";
                  };
                }
              ];
            }
          ];
        };
    in
    (pkgs.formats.yaml { }).generate "missing-evidence-tests.yaml" {
      rule_files = [ "rules.yaml" ];
      evaluation_interval = "1m";
      tests = map hostCase (builtins.attrNames alertData.expectedBackupEvidence) ++ [
        {
          interval = "1m";
          input_series = [ ];
          alert_rule_test = [
            {
              eval_time = "90m";
              alertname = "BackupEvidenceMissing";
              exp_alerts = [ ];
            }
          ];
        }
      ];
    };

  observabilityAlertsLint =
    pkgs.runCommand "observability-alerts-lint" { nativeBuildInputs = [ pkgs.prometheus.cli ]; }
      ''
        promtool check rules ${rulesYaml}
        # Deleting an alert is not a lint error; pin the ones that guard backups,
        # failed units and liveness so removing one fails here.
        for alert in ${lib.escapeShellArgs requiredAlerts}; do
          grep -q "alert: $alert\$" ${rulesYaml} || { echo "missing required alert: $alert" >&2; exit 1; }
        done
        cp ${rulesYaml} rules.yaml
        cp ${missingEvidenceTests} tests.yaml
        promtool test rules tests.yaml
        touch $out
      '';

  observabilityStackFixture =
    let
      systemConfig = lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          self.nixosModules.observability-stack
          (
            { pkgs, ... }:
            {
              networking.hostName = "observability-fixture";
              system.stateVersion = "26.05";

              profiles.observability = {
                enable = true;
                grafana = {
                  enable = true;
                  adminPasswordFile = pkgs.writeText "grafana-admin-password" "test-password";
                };
                loki.enable = true;
                alerts.enable = true;
                collectors = {
                  metrics.enable = true;
                  logs.enable = true;
                };
              };
            }
          )
        ];
      };
      evaluated = {
        grafana = systemConfig.config.services.grafana.enable;
        loki = systemConfig.config.services.loki.enable;
        alertmanager = systemConfig.config.services.prometheus.alertmanager.enable;
        prometheus = systemConfig.config.services.prometheus.enable;
      };
      expected = {
        grafana = true;
        loki = true;
        alertmanager = true;
        prometheus = true;
      };
    in
    assert lib.assertMsg (
      evaluated == expected
    ) "observability-stack-fixture: ${builtins.toJSON evaluated}";
    pkgs.writeText "observability-stack-fixture.json" (builtins.toJSON evaluated);

  observabilityClientFixture =
    let
      passwordFile = pkgs.writeText "observability-ingest-password" "test-password";
      systemConfig = lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          # Imported alone: the client pulls in the stack module it configures.
          self.nixosModules.observability-client
          {
            networking.hostName = "observability-client-fixture";
            system.stateVersion = "26.05";

            profiles.observability-client = {
              enable = true;
              remoteEndpoint = {
                # scheme intentionally unset: the default must be https.
                host = "observability.example.ts.net";
                metricsPath = "/ingest/metrics";
                logsPath = "/ingest/logs";
              };
              ingestAuth = {
                inherit passwordFile;
              };
            };
          }
        ];
      };
      evaluated = {
        metricsURL = (builtins.head systemConfig.config.services.prometheus.remoteWrite).url;
        logsEnabled = systemConfig.config.services.alloy.enable;
      };
      expected = {
        metricsURL = "https://observability.example.ts.net/ingest/metrics";
        logsEnabled = true;
      };
    in
    assert lib.assertMsg (
      evaluated == expected
    ) "observability-client-fixture: ${builtins.toJSON evaluated}";
    pkgs.writeText "observability-client-fixture.json" (builtins.toJSON evaluated);

  observabilityDashboardBackendAssertionFixture =
    let
      dash = import ../../lib/dashboards.nix;
      passwordFile = pkgs.writeText "grafana-admin-password" "test-password";
      badEvaluation = builtins.tryEval (
        builtins.deepSeq
          (lib.nixosSystem {
            system = pkgs.stdenv.hostPlatform.system;
            modules = [
              self.nixosModules.observability-stack
              {
                networking.hostName = "observability-dashboard-backend-mismatch-fixture";
                system.stateVersion = "26.05";

                profiles.observability = {
                  enable = true;
                  grafana = {
                    enable = true;
                    adminPasswordFile = passwordFile;
                  };
                  collectors.metrics.enable = false;
                  dashboards.metrics-without-backend = {
                    enable = true;
                    definition = dash.mkDashboard {
                      uid = "metrics-without-backend";
                      title = "Metrics Without Backend";
                      panels = [
                        (dash.statPanel {
                          id = 1;
                          title = "Metric";
                          ds = dash.prometheusDS;
                          gridPos = dash.gridPos { };
                          targets = [
                            (dash.target { expr = "up"; })
                          ];
                        })
                      ];
                    };
                  };
                };
              }
            ];
          }).config.system.build.toplevel.drvPath
          true
      );
    in
    if badEvaluation.success then
      throw "observability dashboard/backend assertion fixture unexpectedly evaluated"
    else
      pkgs.runCommand "observability-dashboard-backend-assertion-fixture" { } "touch $out";
in
{
  checks = {
    observability-alerts-lint = observabilityAlertsLint;
    observability-stack-fixture = observabilityStackFixture;
    observability-client-fixture = observabilityClientFixture;
    observability-dashboard-backend-assertion-fixture = observabilityDashboardBackendAssertionFixture;
  };
}
