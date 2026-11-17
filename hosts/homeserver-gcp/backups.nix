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
      # The backup itself, its metric and the weekly check come from
      # profiles/backup.nix.
      restic-check-b2 = {
        description = "Restic B2 repository integrity check";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
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

            ${pkgs.restic}/bin/restic \
              --repository-file=${config.sops.secrets.restic_repository.path} \
              --no-cache \
              dump --path ${canaryDir} latest "$canary_path" > "$workdir/canary.txt"
            ${pkgs.gnugrep}/bin/grep -qx '${canaryContent}' "$workdir/canary.txt"

            # The file canary above proves the repo is restorable, but not that a
            # database in it is intact. Restore the consistent Grafana snapshot
            # (grafana.db.backup, produced by backupPrepareCommand; the live
            # grafana.db is excluded) and check it, so a torn or corrupt backup
            # fails here instead of being discovered during a real restore.
            ${pkgs.restic}/bin/restic \
              --repository-file=${config.sops.secrets.restic_repository.path} \
              --no-cache \
              dump --path /var/lib/grafana latest /var/lib/grafana/grafana.db.backup \
              > "$workdir/grafana.db"
            integrity=$(${pkgs.sqlite}/bin/sqlite3 "$workdir/grafana.db" 'PRAGMA integrity_check;')
            [ "$integrity" = "ok" ]

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

    timers.restic-restore-canary-b2 = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "04:30";
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };

    tmpfiles.rules = [
      "d ${canaryDir} 0755 root root -"
      "d /var/lib/restic-staging 0750 root root -"
    ];
  };

  services.restic.backups.b2 = {
    paths = [
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
    '';
    exclude = [
      "/var/lib/grafana/grafana.db"
      "/var/lib/grafana/grafana.db-wal"
      "/var/lib/grafana/grafana.db-shm"
      # AdGuard's query log (90-day retention, tailnet-wide DNS traffic) is
      # 289M+ and growing — it's the main driver behind the B2 storage-cap
      # exhaustion that stopped backups on 2026-07-11. It's rewritten whole
      # on every backup run, so restic can't dedup it between snapshots, and
      # it isn't needed to restore AdGuard's actual state (filters, custom
      # rules, client policy) — see restore-adguard.md.
      "/var/lib/restic-staging/adguardhome/data/querylog.json"
    ];
  };
}
