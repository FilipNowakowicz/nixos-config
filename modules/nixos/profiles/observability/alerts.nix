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
    services.prometheus = {
      ruleFiles = [ ((pkgs.formats.yaml { }).generate "infrastructure-alerts.yaml" alertData.rules) ];
      alertmanagers = [ { static_configs = [ { targets = [ "127.0.0.1:9093" ]; } ]; } ];
      alertmanager = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 9093;
        # Single instance: no gossip listener on the tailnet.
        extraFlags = [ "--cluster.listen-address=" ];
        configuration =
          alertData.alertmanager
          // lib.optionalAttrs webhookEnabled {
            route = alertData.alertmanager.route // {
              receiver = "webhook";
            };
            receivers = alertData.alertmanager.receivers ++ [
              {
                name = "webhook";
                webhook_configs = [
                  {
                    url_file = toString cfg.alertWebhookUrlFile;
                    send_resolved = true;
                  }
                ];
              }
            ];
          };
      };
    };
  };
}
