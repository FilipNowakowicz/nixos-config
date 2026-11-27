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
    "DnsProbeFailed"
    "ScrapeTargetDown"
    "GcpBuilderLeftRunning"
    "Watchdog"
  ];

  # Expected alert for `alertname` with `labels`: the rule's own severity and
  # annotations, with {{ $labels.x }} and {{ $value }} filled in, so a test
  # pins the firing behaviour without restating every description.
  rulesByName = lib.listToAttrs (
    map (rule: lib.nameValuePair rule.alert rule) (
      lib.concatMap (group: group.rules) alertData.rules.groups
    )
  );
  expectAlert =
    alertname:
    {
      labels,
      value ? "",
    }:
    let
      rule = rulesByName.${alertname};
      render = lib.replaceStrings (
        map (name: "{{ $labels.${name} }}") (builtins.attrNames labels) ++ [ "{{ $value }}" ]
      ) (builtins.attrValues labels ++ [ value ]);
    in
    {
      exp_labels = labels // {
        inherit (rule.labels) severity;
      };
      exp_annotations = builtins.mapAttrs (_: render) rule.annotations;
    };
  alertTest = eval_time: alertname: exp_alerts: { inherit eval_time alertname exp_alerts; };

  # promtool unit tests for the blind-spot rules (#628): each fires after its
  # hold and stays quiet before it or on healthy input.
  blindSpotTests =
    let
      dnsLabels = {
        job = "dns-adguard";
        probe = "adguard";
        instance = "100.64.0.53:53";
      };
      lokiLabels = {
        job = "loki";
        instance = "127.0.0.1:3100";
        host = "homeserver-gcp";
      };
      builderLabels = {
        peer = "gcp-builder";
        job = "node";
        instance = "127.0.0.1:9100";
      };
      lynisLabels = {
        job = "node";
        instance = "127.0.0.1:9100";
      };
      series = labels: values: {
        series = "${labels.__name__ or ""}{${
          lib.concatStringsSep "," (
            lib.mapAttrsToList (k: v: ''${k}="${v}"'') (removeAttrs labels [ "__name__" ])
          )
        }}";
        inherit values;
      };
    in
    [
      {
        # Failing DNS probe: DnsProbeFailed after 5 m, and the HTTP-oriented
        # BlackboxProbeFailed never claims the dns- job.
        interval = "1m";
        input_series = [ (series (dnsLabels // { __name__ = "probe_success"; }) "0x20") ];
        alert_rule_test = [
          (alertTest "4m" "DnsProbeFailed" [ ])
          (alertTest "6m" "DnsProbeFailed" [ (expectAlert "DnsProbeFailed" { labels = dnsLabels; }) ])
          (alertTest "6m" "BlackboxProbeFailed" [ ])
        ];
      }
      {
        interval = "1m";
        input_series = [ (series (dnsLabels // { __name__ = "probe_success"; }) "1x20") ];
        alert_rule_test = [ (alertTest "10m" "DnsProbeFailed" [ ]) ];
      }
      {
        # A self-scraped stack component stops answering at 2 m.
        interval = "1m";
        input_series = [ (series (lokiLabels // { __name__ = "up"; }) "1 1 0x20") ];
        alert_rule_test = [
          (alertTest "6m" "ScrapeTargetDown" [ ])
          (alertTest "8m" "ScrapeTargetDown" [ (expectAlert "ScrapeTargetDown" { labels = lokiLabels; }) ])
        ];
      }
      {
        # Builder online continuously: quiet at 3 h 50 m, firing after 4 h.
        interval = "5m";
        input_series = [ (series (builderLabels // { __name__ = "tailscale_peer_online"; }) "1x60") ];
        alert_rule_test = [
          (alertTest "230m" "GcpBuilderLeftRunning" [ ])
          (alertTest "250m" "GcpBuilderLeftRunning" [
            (expectAlert "GcpBuilderLeftRunning" { labels = builderLabels; })
          ])
        ];
      }
      {
        # Normal on-demand use: online for an hour, then powered off again.
        interval = "5m";
        input_series = [
          (series (builderLabels // { __name__ = "tailscale_peer_online"; }) "1x12 0x48")
        ];
        alert_rule_test = [ (alertTest "250m" "GcpBuilderLeftRunning" [ ]) ];
      }
      {
        # Always firing, with no input at all.
        interval = "1m";
        input_series = [ ];
        alert_rule_test = [
          (alertTest "1m" "Watchdog" [ (expectAlert "Watchdog" { labels = { }; }) ])
        ];
      }
      {
        # Healthy baseline 77 stays quiet; a broken audit's 58 fires.
        interval = "1m";
        input_series = [
          (series (lynisLabels // { __name__ = "lynis_hardening_index"; }) "77x5 58x5")
        ];
        alert_rule_test = [
          (alertTest "3m" "LynisScoreLow" [ ])
          (alertTest "8m" "LynisScoreLow" [
            (expectAlert "LynisScoreLow" {
              labels = lynisLabels;
              value = "58";
            })
          ])
        ];
      }
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
      tests =
        map hostCase (builtins.attrNames alertData.expectedBackupEvidence)
        ++ [
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
        ]
        ++ blindSpotTests;
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
                alertWebhookUrlFile = "/run/fixture-webhook-url";
                watchdogUrlFile = "/run/fixture-watchdog-url";
                collectors = {
                  metrics.enable = true;
                  logs.enable = true;
                };
              };
            }
          )
        ];
      };
      amRoute = systemConfig.config.services.prometheus.alertmanager.configuration.route;
      evaluated = {
        grafana = systemConfig.config.services.grafana.enable;
        loki = systemConfig.config.services.loki.enable;
        alertmanager = systemConfig.config.services.prometheus.alertmanager.enable;
        prometheus = systemConfig.config.services.prometheus.enable;
        # Watchdog goes only to its own receiver; everything else to the webhook.
        routes = map (route: { inherit (route) receiver matchers; }) amRoute.routes;
        defaultReceiver = amRoute.receiver;
        # The alerting host scrapes its own stack components.
        scrapeJobs = map (scrape: scrape.job_name) systemConfig.config.services.prometheus.scrapeConfigs;
        grafanaMetricsPath =
          (lib.findFirst (
            scrape: scrape.job_name == "grafana"
          ) { } systemConfig.config.services.prometheus.scrapeConfigs).metrics_path or null;
      };
      expected = {
        grafana = true;
        loki = true;
        alertmanager = true;
        prometheus = true;
        routes = [
          {
            receiver = "watchdog";
            matchers = [ ''alertname="Watchdog"'' ];
          }
        ];
        defaultReceiver = "webhook";
        scrapeJobs = [
          "prometheus"
          "node"
          "alertmanager"
          "grafana"
          "loki"
          "alloy"
        ];
        grafanaMetricsPath = "/metrics";
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
