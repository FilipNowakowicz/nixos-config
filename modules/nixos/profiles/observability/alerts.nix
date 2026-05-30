# Mimir ruler alert rules and minimal Alertmanager config.
# Rules are provisioned declaratively via systemd-tmpfiles (C+ copy from nix store).
# Mimir's ruler polls ruler_storage for changes; rules take effect after the next
# poll cycle without a restart.
#
# The rule/alertmanager data lives in lib/observability-alerts.nix so the
# observability-alerts-lint flake check (promtool check rules) validates the
# exact same source this module renders. Thresholds are documented there.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.profiles.observability;
  mkYaml = name: data: (pkgs.formats.yaml { }).generate name data;

  alertData = import ../../../../lib/observability-alerts.nix;

  rulesFile = mkYaml "infrastructure-alerts.yaml" alertData.rules;

  # Alertmanager config layered on the shared base in lib/observability-alerts.nix
  # (null route + null receiver). When `alertWebhookUrlFile` is set, alerts are
  # routed to a webhook receiver (ntfy.sh format: POST the alert JSON to the URL).
  # Override further in host config via lib.mkForce if needed.
  webhookEnabled = cfg.alertWebhookUrlFile != null;
  alertmanagerFile = mkYaml "alertmanager.yaml" (
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
    }
  );
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
