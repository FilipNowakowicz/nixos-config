{ config, pkgs, ... }:
{
  systemd.services = {
    restic-backups-b2.serviceConfig.ExecStartPost = pkgs.writeShellScript "restic-backup-metrics" ''
      tmp=/var/lib/node-exporter-textfiles/restic_backup.prom.tmp
      {
        echo "# HELP restic_last_backup_timestamp_seconds Unix timestamp of last successful restic backup"
        echo "# TYPE restic_last_backup_timestamp_seconds gauge"
        echo "restic_last_backup_timestamp_seconds $(date +%s)"
      } > "$tmp"
      mv "$tmp" /var/lib/node-exporter-textfiles/restic_backup.prom
    '';

    restic-check-b2 = {
      description = "Restic B2 repository integrity check";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = {
        RESTIC_REPOSITORY = "b2:filipnowakowicz-gcp:";
        RESTIC_PASSWORD_FILE = config.sops.secrets.restic_password.path;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.restic}/bin/restic check --read-data-subset=1G";
        ExecStartPost = pkgs.writeShellScript "restic-check-metrics" ''
          tmp=/var/lib/node-exporter-textfiles/restic_check.prom.tmp
          {
            echo "# HELP restic_last_check_timestamp_seconds Unix timestamp of last successful restic integrity check"
            echo "# TYPE restic_last_check_timestamp_seconds gauge"
            echo "restic_last_check_timestamp_seconds $(date +%s)"
          } > "$tmp"
          mv "$tmp" /var/lib/node-exporter-textfiles/restic_check.prom
        '';
        EnvironmentFile = config.sops.secrets.b2_credentials.path;
      };
    };
  };

  systemd.timers.restic-check-b2 = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      RandomizedDelaySec = "2h";
      Persistent = true;
    };
  };

  services.restic.backups.b2 = {
    paths = [
      "/var/lib/vaultwarden"
      "/var/lib/grafana"
      "/var/lib/AdGuardHome"
    ];
    repository = "b2:filipnowakowicz-gcp:";
    passwordFile = config.sops.secrets.restic_password.path;
    environmentFile = config.sops.secrets.b2_credentials.path;
  };
}
