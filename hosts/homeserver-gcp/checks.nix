# Invariants that guard hosts/homeserver-gcp alone, beside the config they
# read. flake/checks.nix layers `invariants` on the fleet baseline for
# `invariants-homeserver-gcp` and feeds `inventoryAssertions` to the inventory.
{ lib, invariants, ... }:
let
  inherit (invariants) mkResult requirePaths;

  runnerChecks = import ./github-runner-checks.nix { inherit lib; };

  homeserverSshAndHttpsTailscaleOnly = {
    name = "SSH and HTTPS stay Tailscale-only";
    check =
      cfg:
      invariants.checkTCPPortsRestrictedToInterface {
        interface = "tailscale0";
        ports = [
          22
          443
        ];
      } cfg;
  };

  homeserverGcpB2BackupUsesCriticalPolicy = {
    name = "homeserver-gcp B2 backup uses critical policy";
    check =
      cfg:
      let
        backup = cfg.services.restic.backups.b2;
        # Same source modules/nixos/profiles/backup.nix uses, so this can't
        # drift out of sync with the policy that's actually applied.
        # Pinned literally (not read from lib/backup-policy.nix): a shared
        # source would let a retention cut change policy and expectation together.
        expectedPruneOpts = [
          "--group-by host"
          "--keep-daily 14"
          "--keep-weekly 8"
          "--keep-monthly 6"
          "--keep-yearly 2"
        ];
        pathCheck = requirePaths backup.paths [
          "/var/lib/grafana"
          "/var/lib/restic-backup-canary"
          "/var/lib/restic-staging/adguardhome"
        ];
        violations = lib.filter (msg: msg != "") [
          (lib.optionalString (
            !(lib.hasPrefix "/run/secrets/" (backup.repositoryFile or ""))
          ) "services.restic.backups.b2.repositoryFile must come from /run/secrets/*")
          (lib.optionalString (
            !(lib.hasPrefix "/run/secrets/" (backup.passwordFile or ""))
          ) "services.restic.backups.b2.passwordFile must come from /run/secrets/*")
          (lib.optionalString (
            !(lib.hasPrefix "/run/secrets/" (backup.environmentFile or ""))
          ) "services.restic.backups.b2.environmentFile must come from /run/secrets/*")
          (lib.optionalString (!backup.initialize) "services.restic.backups.b2.initialize must be true")
          (lib.optionalString (
            backup.pruneOpts != expectedPruneOpts
          ) "services.restic.backups.b2.pruneOpts must match the critical retention class")
          (lib.optionalString (
            (backup.timerConfig.OnCalendar or null) != "daily"
          ) "services.restic.backups.b2.timerConfig.OnCalendar must be \"daily\"")
          (lib.optionalString (!pathCheck.passed) pathCheck.message)
        ];
      in
      mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
  };

  alertDeliveryHasFailedUnitFallback = {
    name = "alerting stack has direct failed-unit webhook fallback";
    check =
      cfg:
      let
        notifier = cfg.services.systemd-failure-notify;
        expectedUnits = [
          "alertmanager"
          "heartbeat-ping"
          "nginx"
          "prometheus"
          "prometheus-node-exporter"
          "tailscaled"
        ];
        actualUnits = lib.sort builtins.lessThan notifier.services;
        violations = lib.filter (msg: msg != "") [
          (lib.optionalString (!notifier.enable) "services.systemd-failure-notify.enable must be true")
          (lib.optionalString (
            notifier.webhookUrlFile != "/run/secrets/alertmanager_webhook_url"
          ) "services.systemd-failure-notify.webhookUrlFile must use /run/secrets/alertmanager_webhook_url")
          (lib.optionalString (
            actualUnits != expectedUnits
          ) "services.systemd-failure-notify.services must cover the alerting/reachability stack")
        ];
      in
      mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
  };
in
{
  invariants = invariants.deployTargetAccessAssertions ++ [
    homeserverSshAndHttpsTailscaleOnly
    runnerChecks.selfSwitch
    runnerChecks.runbook
    homeserverGcpB2BackupUsesCriticalPolicy
    alertDeliveryHasFailedUnitFallback
  ];

  # The subset reported per host in the generated inventory.
  inventoryAssertions = invariants.deployTargetAccessAssertions ++ [
    homeserverSshAndHttpsTailscaleOnly
  ];
}
