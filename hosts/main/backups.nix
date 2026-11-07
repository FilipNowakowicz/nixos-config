{ config, pkgs, ... }:
let
  inherit (config.lib.profiles.observability) mkPromScript;
in
{
  # Hidden maintenance mount for the filesystem top-level. btrbk snapshots
  # subvolumes by their real top-level names (`@home`, `@persist`) rather than
  # via nested mount paths.
  fileSystems."/.btrfs-root" = {
    device = "/dev/disk/by-label/main-root";
    fsType = "btrfs";
    options = [
      "subvol=/"
      "noatime"
      "discard=async"
    ];
  };

  services = {
    btrbk.instances.local = {
      onCalendar = "daily";
      snapshotOnly = true;
      settings = {
        snapshot_preserve_min = "2d";
        snapshot_preserve = "14d";
        volume."/.btrfs-root" = {
          snapshot_dir = ".snapshots";
          subvolume = {
            "@home" = { };
            "@persist" = { };
          };
        };
      };
    };

    restic.backups.local = {
      paths = [
        "/home/user/.ssh"
        "/home/user/.gnupg"
        "/home/user/nix"
        "/home/user/.mozilla/firefox"
        "/home/user/.config/mozilla/firefox"
        "/home/user/.config/spotify"
        "/home/user/.config/discord"
        "/home/user/.config/gh"
        "/home/user/.config/gcloud"
        "/home/user/.local/share/Anki2"
        "/home/user/.config/chromium"
        "/home/user/.local/share/kwalletd"
        "/home/user/.codex"
        "/home/user/.claude"
        "/home/user/.claude.json"
        "/home/user/.config/sops"
        "/etc/machine-id"
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
        "/etc/NetworkManager/system-connections"
        "/etc/mullvad-vpn"
        "/var/lib/tailscale"
        "/var/lib/bluetooth"
        "/var/lib/fprint"
        "/var/lib/tudor"
        "/var/lib/sbctl"
        "/var/lib/usbguard"
        # libvirt domain definitions + Whonix KVM disk images. Persisted only
        # here, so disk loss would otherwise destroy the VMs with no off-host
        # copy. Large/volatile/re-derivable bulk (installer ISOs, transient
        # snapshots, runtime save/dump images) is excluded below.
        "/var/lib/libvirt"
      ];
      exclude = [
        # Token/credential caches — not durable; regenerated on next gcloud auth
        "/home/user/.config/gcloud/access_tokens.db"
        "/home/user/.config/gcloud/credentials.db"
        "/home/user/.config/gcloud/logs"
        "/home/user/.config/gcloud/legacy_credentials"
        # libvirt: skip large, volatile, or re-derivable artefacts. Installer
        # ISOs are re-downloadable upstream; *.snap are transient disk
        # snapshots; save/dump/ram are runtime hibernation + crash images.
        "/var/lib/libvirt/images/*.iso"
        "/var/lib/libvirt/images/*.snap"
        "/var/lib/libvirt/qemu/save"
        "/var/lib/libvirt/qemu/dump"
        "/var/lib/libvirt/qemu/ram"
        "/var/lib/libvirt/qemu/snapshot"
      ];
      repositoryFile = config.sops.secrets.restic_repository.path;
      passwordFile = config.sops.secrets.restic_password.path;
      environmentFile = config.sops.secrets.b2_credentials.path;
    };
  };

  systemd = {
    services = {
      restic-backups-local.serviceConfig.ExecStartPost = mkPromScript {
        name = "restic_backup.prom";
        lines = [
          "# HELP restic_last_backup_timestamp_seconds Unix timestamp of last successful restic backup"
          "# TYPE restic_last_backup_timestamp_seconds gauge"
          "restic_last_backup_timestamp_seconds $(${pkgs.coreutils}/bin/date +%s)"
        ];
      };

      btrbk-local-snapshot-dir = {
        description = "Ensure btrbk local snapshot directory exists";
        requiredBy = [ "btrbk-local.service" ];
        before = [ "btrbk-local.service" ];
        unitConfig.RequiresMountsFor = "/.btrfs-root";
        serviceConfig.Type = "oneshot";
        script = ''
          ${pkgs.coreutils}/bin/install -d -m 0750 -o btrbk -g btrbk /.btrfs-root/.snapshots
        '';
      };

      restic-check-local = {
        description = "Restic workstation repository integrity check";
        # network-online.target is a no-op here: main force-disables both
        # wait-online providers (see networking.nix), so the target is reached
        # immediately and orders against nothing. Probe the B2 backend directly
        # with a bounded retry in ExecStartPre instead, so the check waits for
        # real connectivity rather than relying on a target that never blocks.
        environment.RESTIC_PASSWORD_FILE = config.sops.secrets.restic_password.path;
        serviceConfig = {
          Type = "oneshot";
          ExecStartPre = pkgs.writeShellScript "restic-check-wait-repo" ''
            for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
              ${pkgs.restic}/bin/restic cat config \
                --repository-file=${config.sops.secrets.restic_repository.path} \
                >/dev/null 2>&1 && exit 0
              ${pkgs.coreutils}/bin/sleep 10
            done
            echo "restic-check-local: B2 repo unreachable after ~5min" >&2
            exit 1
          '';
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
    };

    timers.restic-check-local = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        RandomizedDelaySec = "2h";
        Persistent = true;
      };
    };
  };
}
