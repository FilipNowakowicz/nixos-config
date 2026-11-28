# Shared infrastructure rules, evaluated by the central Prometheus server.
# The lint check validates the same data with promtool.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.profiles.observability;
  alertData = import ../../../../lib/observability-alerts.nix;
  webhookEnabled = cfg.alertWebhookUrlFile != null;
  watchdogEnabled = cfg.watchdogUrlFile != null;

  inherit (config.services) grafana loki alloy;
  inherit (config.services.prometheus) alertmanager exporters;

  # With serve_from_sub_path, Grafana serves /metrics under root_url's path
  # (/grafana/metrics) and redirects the bare path.
  grafanaPathPrefix =
    let
      server = grafana.settings.server;
      match = builtins.match "[^/]*//[^/]*(/.*)" server.root_url;
    in
    if (server.serve_from_sub_path or false) && match != null then
      lib.removeSuffix "/" (builtins.head match)
    else
      "";

  selfScrape =
    job_name: address: extra:
    {
      inherit job_name;
      static_configs = [ { targets = [ address ]; } ];
    }
    // extra;

  # The alerting host watches its own stack, so ScrapeTargetDown fires when a
  # component that has no unit failure (hung, wedged listener) stops answering.
  selfScrapeConfigs = [
    (selfScrape "alertmanager" "${alertmanager.listenAddress}:${toString alertmanager.port}" { })
  ]
  ++ lib.optional grafana.enable (
    selfScrape "grafana"
      "${grafana.settings.server.http_addr}:${toString grafana.settings.server.http_port}"
      { metrics_path = "${grafanaPathPrefix}/metrics"; }
  )
  ++ lib.optional loki.enable (
    selfScrape "loki"
      "${loki.configuration.server.http_listen_address}:${toString loki.configuration.server.http_listen_port}"
      { }
  )
  # Alloy's default HTTP server address; the module passes no override.
  ++ lib.optional alloy.enable (selfScrape "alloy" "127.0.0.1:12345" { })
  # Not `blackbox-*`: those jobs are probes, which the probe alerts match.
  ++ lib.optional exporters.blackbox.enable (
    selfScrape "exporter-blackbox" "127.0.0.1:${toString exporters.blackbox.port}" { }
  );

  watchdogRoute =
    alertData.alertmanager.watchdogRoute
    // lib.optionalAttrs watchdogEnabled {
      receiver = "watchdog";
    };
in
{
  options.profiles.observability.alerts.enable =
    lib.mkEnableOption "infrastructure alert evaluation and Alertmanager";

  config = lib.mkIf (cfg.enable && cfg.alerts.enable) {
    assertions = [
      {
        assertion = cfg.collectors.metrics.enable;
        message = "profiles.observability.alerts.enable requires collectors.metrics.enable";
      }
    ];
    profiles.observability.collectors.metrics.extraScrapeConfigs = selfScrapeConfigs;
    services.prometheus = {
      ruleFiles = [ ((pkgs.formats.yaml { }).generate "infrastructure-alerts.yaml" alertData.rules) ];
      alertmanagers = [ { static_configs = [ { targets = [ "127.0.0.1:9093" ]; } ]; } ];
      alertmanager = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 9093;
        # Single instance: no gossip listener on the tailnet.
        extraFlags = [ "--cluster.listen-address=" ];
        configuration = {
          route =
            alertData.alertmanager.route
            // lib.optionalAttrs webhookEnabled { receiver = "webhook"; }
            // {
              routes = [ watchdogRoute ];
            };
          receivers =
            alertData.alertmanager.receivers
            ++ lib.optional webhookEnabled {
              name = "webhook";
              webhook_configs = [
                {
                  url_file = toString cfg.alertWebhookUrlFile;
                  send_resolved = true;
                }
              ];
            }
            ++ lib.optional watchdogEnabled {
              name = "watchdog";
              webhook_configs = [
                {
                  url_file = toString cfg.watchdogUrlFile;
                  send_resolved = false;
                }
              ];
            };
        };
      };
    };
  };
}
