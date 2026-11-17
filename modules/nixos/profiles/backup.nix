{
  config,
  lib,
  pkgs,
  hostMeta,
  ...
}:
let
  backup = hostMeta.backup or { };
  backupClass = backup.class or null;
  backupName = backup.name or "local";
  inherit (config.sops) secrets;
  inherit (config.lib.profiles.observability) mkPromScript;

  # Canonical definition (and the rationale for --group-by host) lives in
  # lib/backup-policy.nix; flake/checks.nix's homeserver-gcp invariant reads
  # the same file so the two can't drift out of sync.
  pruneOptsByClass = import ../../../lib/backup-policy.nix;

  timestampMetric = file: metric: help: {
    name = file;
    lines = [
      "# HELP ${metric} ${help}"
      "# TYPE ${metric} gauge"
      "${metric} $(${pkgs.coreutils}/bin/date +%s)"
    ];
  };
in
# Every backed-up host keeps its repository location, password and B2
# credentials in the same three sops secrets, takes a daily snapshot, and
# checks the repository weekly. Hosts add paths, excludes, prepare commands,
# the check unit's description and any network ordering it needs.
lib.mkIf (backupClass != null) {
  sops.secrets = {
    restic_password = { };
    restic_repository = { };
    b2_credentials = { };
  };

  services.restic.backups.${backupName} = {
    initialize = true;
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
    pruneOpts = pruneOptsByClass.${backupClass};
    repositoryFile = secrets.restic_repository.path;
    passwordFile = secrets.restic_password.path;
    environmentFile = secrets.b2_credentials.path;
  };

  systemd = {
    services = {
      # ExecStartPost only runs after every ExecStart command succeeds, so
      # reaching this script already means the backup completed cleanly — stamp
      # the freshness metric unconditionally. ($EXIT_STATUS is only exported to
      # ExecStop/ExecStopPost, never to ExecStartPost, so it cannot gate here.)
      "restic-backups-${backupName}".serviceConfig.ExecStartPost = mkPromScript (
        timestampMetric "restic_backup.prom" "restic_last_backup_timestamp_seconds"
          "Unix timestamp of last successful restic backup"
      );

      "restic-check-${backupName}" = {
        environment.RESTIC_PASSWORD_FILE = secrets.restic_password.path;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.restic}/bin/restic check --repository-file=${secrets.restic_repository.path} --read-data-subset=1G";
          ExecStartPost = mkPromScript (
            timestampMetric "restic_check.prom" "restic_last_check_timestamp_seconds"
              "Unix timestamp of last successful restic integrity check"
          );
          EnvironmentFile = secrets.b2_credentials.path;
        };
      };
    };

    timers."restic-check-${backupName}" = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        RandomizedDelaySec = "2h";
        Persistent = true;
      };
    };
  };
}
