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
  inherit (config.lib.profiles.observability) mkPromScript nodeExporterTextfileDir;
  inherit (config.profiles.observability.collectors.metrics) durableTextfileDir;

  # Canonical definition (and the rationale for --group-by host) lives in
  # lib/backup-policy.nix. The homeserver check pins its own expected values
  # so an accidental reduction in retention fails evaluation.
  pruneOptsByClass = import ../../../lib/backup-policy.nix;
  evidence = (import ../../../lib/backup-evidence.nix).metrics;

  # Success stamps go to the durable directory. If a reboot erased them, the
  # *Stale alerts would have no series to age and could never fire.
  timestampMetric = file: metric: help: {
    name = file;
    dir = durableTextfileDir;
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
    # Remove stamps written before the durable directory moved, so
    # node_exporter never reads the same series from two files.
    tmpfiles.rules = lib.optionals (durableTextfileDir != nodeExporterTextfileDir) [
      "r ${nodeExporterTextfileDir}/restic_backup.prom"
      "r ${nodeExporterTextfileDir}/restic_check.prom"
    ];

    services = {
      # ExecStartPost only runs after every ExecStart command succeeds, so
      # reaching this script already means the backup completed cleanly — stamp
      # the freshness metric unconditionally. ($EXIT_STATUS is only exported to
      # ExecStop/ExecStopPost, never to ExecStartPost, so it cannot gate here.)
      "restic-backups-${backupName}".serviceConfig.ExecStartPost = mkPromScript (
        timestampMetric "restic_backup.prom" evidence.backup
          "Unix timestamp of last successful restic backup"
      );

      "restic-check-${backupName}" = {
        environment.RESTIC_PASSWORD_FILE = secrets.restic_password.path;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.restic}/bin/restic check --repository-file=${secrets.restic_repository.path} --read-data-subset=1G";
          ExecStartPost = mkPromScript (
            timestampMetric "restic_check.prom" evidence.check
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
