# Back up the phone's shared storage (/storage/emulated/0) to B2 over KDE
# Connect (#597). It runs as the user, because KDE Connect mounts the phone with
# sshfs under $XDG_RUNTIME_DIR, where root can't read it.
#
# The phone is only sometimes reachable, so an hourly timer tries and skips
# quietly unless the phone is reachable and charging, or a backup has already
# succeeded in the last 20 hours. A separate daily check sends an ntfy alert
# when nothing has succeeded for 7 days, so the job can't go silent.
#
# Scope is a mirror, not an archive: the shared `standard` retention applies, so
# a photo deleted from the phone ages out with its last snapshot. Android hides
# Android/data, Android/obb and app data from other programs, so those are not
# reachable here. WhatsApp and the phone's own cloud backup cover them.
#
# The importing user module names the phone and the secrets through
# `fleet.phoneBackup.*`; none of them has a default.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.phoneBackup;
  inherit (cfg) deviceId;
  devicePath = "/modules/kdeconnect/devices/${deviceId}";

  inherit (config.sops) secrets;
  stateDir = "${config.xdg.stateHome}/phone-backup";
  pruneOpts = (import ../../lib/backup-policy.nix).standard;

  resticEnv = ''
    set -a
    # shellcheck disable=SC1091
    . ${secrets.phone-backup-b2-credentials.path}
    set +a
    export RESTIC_REPOSITORY_FILE=${secrets.phone-backup-repository.path}
    export RESTIC_PASSWORD_FILE=${secrets.phone-backup-password.path}
  '';

  mountPhone = pkgs.writeShellApplication {
    name = "phone-mount";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      systemd # busctl
    ];
    text = builtins.readFile ../files/scripts/phone-mount.sh;
  };

  backup = pkgs.writeShellApplication {
    name = "phone-backup";
    runtimeInputs = with pkgs; [
      coreutils
      restic
      systemd # busctl
    ];
    text = ''
      mkdir -p ${stateDir}
      last=${stateDir}/last-success

      if [[ -s $last ]] && (($(date +%s) - $(<"$last") < 20 * 3600)); then
        echo "phone-backup: backed up within the last 20 hours; nothing to do"
        exit 0
      fi

      prop() {
        busctl --user get-property org.kde.kdeconnect "$1" "$2" "$3" 2>/dev/null | cut -d' ' -f2 || true
      }
      if [[ $(prop ${devicePath} org.kde.kdeconnect.device isReachable) != true ]]; then
        echo "phone-backup: phone not reachable; skipping"
        exit 0
      fi
      if [[ $(prop ${devicePath}/battery org.kde.kdeconnect.device.battery isCharging) != true ]]; then
        echo "phone-backup: phone not charging; skipping"
        exit 0
      fi

      ${lib.getExe mountPhone} ${deviceId}
      root=$XDG_RUNTIME_DIR/${deviceId}/storage/emulated/0

      ${resticEnv}

      # First run only: init refuses to touch an existing repository, so a
      # transient failure of `cat config` can't overwrite anything.
      restic cat config >/dev/null 2>&1 || restic init

      # sshfs gives files new inode numbers and ctimes on every mount, so
      # restic's default change detection would re-read all 20 GB each run.
      # Size and mtime are what the phone keeps stable.
      restic backup "$root" \
        --host ${lib.escapeShellArg cfg.snapshotHost} \
        --tag phone \
        --ignore-inode \
        --ignore-ctime \
        --exclude '**/.thumbnails' \
        --exclude '**/.trashed-*' \
        --exclude '**/.Trash*' \
        --exclude "$root/Android/data" \
        --exclude "$root/Android/obb"

      restic forget --prune ${toString pruneOpts}

      date +%s >"$last"
    '';
  };

  staleCheck = pkgs.writeShellApplication {
    name = "phone-backup-stale-check";
    runtimeInputs = with pkgs; [
      coreutils
      curl
    ];
    text = ''
      mkdir -p ${stateDir}
      # A first-seen stamp makes "never succeeded" alert too, a week after the
      # job was installed, instead of staying silent forever.
      [[ -s ${stateDir}/first-seen ]] || date +%s >${stateDir}/first-seen

      ref=${stateDir}/last-success
      [[ -s $ref ]] || ref=${stateDir}/first-seen
      age_days=$((($(date +%s) - $(<"$ref")) / 86400))

      if ((age_days >= 7)); then
        curl -fsS --retry 3 \
          -H "Title: Phone backup is stale" \
          -H "Priority: high" \
          -d "No successful phone backup for $age_days days. Leave the phone charging on the tailnet, or check: journalctl --user -u phone-backup" \
          "$(<${secrets.ntfy-topic-url.path})" >/dev/null
      fi
    '';
  };

  inherit (cfg) sopsFile;
  sopsUnit = {
    After = [ "sops-nix.service" ];
    Wants = [ "sops-nix.service" ];
  };
in
{
  options.fleet.phoneBackup = {
    deviceId = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_]+";
      example = "0123456789abcdef0123456789abcdef";
      description = "KDE Connect ID of the paired phone to back up (`kdeconnect-cli -l`).";
    };
    snapshotHost = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9._-]+";
      example = "my-phone";
      description = "Host name recorded on the phone's restic snapshots (`restic backup --host`).";
    };
    sopsFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        sops file holding the backup secrets under the keys
        `restic_repository`, `restic_password` and `b2_credentials`.
      '';
    };
  };

  config = {
    sops.secrets = {
      phone-backup-repository = {
        inherit sopsFile;
        key = "restic_repository";
      };
      phone-backup-password = {
        inherit sopsFile;
        key = "restic_password";
      };
      # B2 application key restricted to the bucket's phone/ prefix.
      phone-backup-b2-credentials = {
        inherit sopsFile;
        key = "b2_credentials";
      };
    };

    home.packages = [
      (pkgs.writeShellApplication {
        name = "phone-restic";
        runtimeInputs = [ pkgs.restic ];
        text = ''
          ${resticEnv}
          exec restic "$@"
        '';
      })
    ];

    systemd.user = {
      services = {
        phone-backup = {
          Unit = sopsUnit // {
            Description = "Back up the phone's shared storage to B2 over KDE Connect";
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${backup}/bin/phone-backup";
            Nice = 10;
            IOSchedulingClass = "idle";
          };
        };

        phone-backup-stale-check = {
          Unit = sopsUnit // {
            Description = "Alert when the phone backup has not succeeded for 7 days";
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${staleCheck}/bin/phone-backup-stale-check";
          };
        };
      };

      timers = {
        phone-backup = {
          Unit.Description = "Try the phone backup hourly";
          Timer = {
            OnCalendar = "hourly";
            RandomizedDelaySec = "10m";
            Persistent = true;
          };
          Install.WantedBy = [ "timers.target" ];
        };

        phone-backup-stale-check = {
          Unit.Description = "Check the phone backup's age daily";
          Timer = {
            OnCalendar = "daily";
            Persistent = true;
          };
          Install.WantedBy = [ "timers.target" ];
        };
      };
    };
  };
}
