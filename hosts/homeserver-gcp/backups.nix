{ config, pkgs, ... }:
let
  canaryDir = "/var/lib/restic-backup-canary";
  canaryFile = "${canaryDir}/homeserver-gcp.txt";
  canaryContent = "restic restore canary: homeserver-gcp";
  inherit (config.lib.profiles.observability) mkPromScript;
in
{
  systemd = {
    services = {
      # ExecStartPost only runs after every ExecStart command succeeds, so
      # reaching this script already means the backup completed cleanly — stamp
      # the freshness metric unconditionally. ($EXIT_STATUS is only exported to
      # ExecStop/ExecStopPost, never to ExecStartPost, so it cannot gate here.)
      restic-backups-b2.serviceConfig.ExecStartPost = mkPromScript {
        name = "restic_backup.prom";
        lines = [
          "# HELP restic_last_backup_timestamp_seconds Unix timestamp of last successful restic backup"
          "# TYPE restic_last_backup_timestamp_seconds gauge"
          "restic_last_backup_timestamp_seconds $(${pkgs.coreutils}/bin/date +%s)"
        ];
      };

      restic-check-b2 = {
        description = "Restic B2 repository integrity check";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        environment.RESTIC_PASSWORD_FILE = config.sops.secrets.restic_password.path;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.restic}/bin/restic check --repository-file=${config.sops.secrets.restic_repository.path} --read-data-subset=1G";
          ExecStartPost = mkPromScript {
            name = "restic_check.prom";
            lines = [
              "# HELP restic_last_check_timestamp_seconds Unix timestamp of last successful restic integrity check"
              "# TYPE restic_last_check_timestamp_seconds gauge"
              "restic_last_check_timestamp_seconds $(${pkgs.coreutils}/bin/date +%s)"
            ];
          };
          EnvironmentFile = config.sops.secrets.b2_credentials.path;
        };
      };

      restic-restore-canary-b2 = {
        description = "Restic B2 restore canary";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        environment.RESTIC_PASSWORD_FILE = config.sops.secrets.restic_password.path;
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = config.sops.secrets.b2_credentials.path;
          ExecStart = pkgs.writeShellScript "restic-restore-canary" ''
            set -eu

            canary_path=${canaryFile}
            workdir=$(${pkgs.coreutils}/bin/mktemp -d /run/restic-restore-canary.XXXXXX)
            trap '${pkgs.coreutils}/bin/rm -rf "$workdir"' EXIT

            ${pkgs.restic}/bin/restic --repository-file=${config.sops.secrets.restic_repository.path} \
              dump latest "$canary_path" > "$workdir/canary.txt"
            ${pkgs.gnugrep}/bin/grep -qx '${canaryContent}' "$workdir/canary.txt"

            ${mkPromScript {
              name = "restic_restore_canary.prom";
              lines = [
                "# HELP restic_last_restore_test_timestamp_seconds Unix timestamp of last successful restic restore canary"
                "# TYPE restic_last_restore_test_timestamp_seconds gauge"
                "restic_last_restore_test_timestamp_seconds $(${pkgs.coreutils}/bin/date +%s)"
              ];
            }}
          '';
        };
      };
    };

    timers = {
      restic-check-b2 = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "weekly";
          RandomizedDelaySec = "2h";
          Persistent = true;
        };
      };

      restic-restore-canary-b2 = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "04:30";
          Persistent = true;
          RandomizedDelaySec = "30m";
        };
      };
    };

    tmpfiles.rules = [
      "d ${canaryDir} 0755 root root -"
      "d /var/lib/restic-staging 0750 root root -"
    ];
  };

  services.restic.backups.b2 = {
    paths = [
      "/var/lib/vaultwarden"
      "/var/lib/grafana"
      canaryDir
      "/var/lib/restic-staging/adguardhome"
    ];
    # Grafana keeps live SQLite state (grafana.db + WAL) at /var/lib/grafana.
    # Backing up the live file risks capturing a torn mid-write state, so emit a
    # consistent snapshot with sqlite3 .backup and exclude the live db/WAL files.
    backupPrepareCommand = ''
      ${pkgs.coreutils}/bin/printf '%s\n' '${canaryContent}' > ${canaryFile}

      ${pkgs.coreutils}/bin/install -d -m 0750 /var/lib/restic-staging/adguardhome
      ${pkgs.rsync}/bin/rsync -a --delete --no-owner --no-group /var/lib/AdGuardHome/ /var/lib/restic-staging/adguardhome/

      ${pkgs.sqlite}/bin/sqlite3 /var/lib/grafana/grafana.db ".backup '/var/lib/grafana/grafana.db.backup'"
      ${pkgs.sqlite}/bin/sqlite3 /var/lib/vaultwarden/db.sqlite3 ".backup '/var/lib/vaultwarden/db.sqlite3.backup'"
    '';
    exclude = [
      "/var/lib/grafana/grafana.db"
      "/var/lib/grafana/grafana.db-wal"
      "/var/lib/grafana/grafana.db-shm"
      "/var/lib/vaultwarden/db.sqlite3"
      "/var/lib/vaultwarden/db.sqlite3-wal"
      "/var/lib/vaultwarden/db.sqlite3-shm"
    ];
    repositoryFile = config.sops.secrets.restic_repository.path;
    passwordFile = config.sops.secrets.restic_password.path;
    environmentFile = config.sops.secrets.b2_credentials.path;
  };
}
