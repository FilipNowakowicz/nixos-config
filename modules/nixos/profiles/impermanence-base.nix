{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.profiles.impermanence.rollbackRoot;
  btrfsMount = "/btrfs_tmp";
  rootPath = "${btrfsMount}/${cfg.rootSubvol}";
  blankRootPath = "${btrfsMount}/${cfg.blankSubvol}";
  oldRootsPath = "${btrfsMount}/${cfg.oldRootsSubvol}";
in
{
  options.profiles.impermanence.rollbackRoot = {
    enable = lib.mkEnableOption ''
      rolling the impermanent root subvolume back to a blank snapshot during initrd boot
    '';

    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/mapper/cryptroot";
      description = "Block device that contains the btrfs root subvolumes.";
    };

    cryptsetupUnit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "systemd-cryptsetup@cryptroot.service";
      description = "Initrd cryptsetup unit the rollback service should wait for, or null for an unencrypted device.";
    };

    rootSubvol = lib.mkOption {
      type = lib.types.str;
      default = "@root";
      description = "Mutable root btrfs subvolume replaced during rollback.";
    };

    blankSubvol = lib.mkOption {
      type = lib.types.str;
      default = "@root-blank";
      description = "Blank btrfs subvolume used as the rollback source.";
    };

    oldRootsSubvol = lib.mkOption {
      type = lib.types.str;
      default = "old_roots";
      description = "Btrfs directory, relative to the top-level subvolume, where previous roots are retained.";
    };
  };

  config = lib.mkMerge [
    {
      # Shared impermanence baseline; hosts extend directories as needed.
      fileSystems."/persist".neededForBoot = true;

      environment.persistence."/persist" = {
        hideMounts = true;
        directories = [
          "/var/log"
          "/var/lib/nixos"
        ];
        files = [
          "/etc/machine-id"
          "/etc/ssh/ssh_host_ed25519_key"
          "/etc/ssh/ssh_host_ed25519_key.pub"
        ];
      };
    }

    (lib.mkIf cfg.enable {
      # btrfs and find aren't in initrd by default; coreutils + mount/umount are.
      boot.initrd.systemd.initrdBin = [
        pkgs.btrfs-progs
        pkgs.findutils
        pkgs.gnused
      ];

      boot.initrd.systemd.services.rollback-root = {
        description = "Roll ${cfg.rootSubvol} back to the empty ${cfg.blankSubvol} btrfs snapshot";
        wantedBy = [ "initrd.target" ];
        after = lib.optional (cfg.cryptsetupUnit != null) cfg.cryptsetupUnit;
        before = [ "sysroot.mount" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig.Type = "oneshot";
        script = ''
          set -euo pipefail

          mkdir -p ${btrfsMount}
          mount -t btrfs -o subvol=/ ${cfg.device} ${btrfsMount}

          if [ -e ${rootPath} ]; then
            timestamp=$(date --date="@$(stat -c %Y ${rootPath})" "+%Y-%m-%d_%H:%M:%S")
            mkdir -p ${oldRootsPath}
            mv ${rootPath} "${oldRootsPath}/$timestamp"
          fi

          delete_subvolume_recursively() {
            IFS=$'\n'
            for i in $(btrfs subvolume list -o "$1" | sed -n 's/.* path //p'); do
              delete_subvolume_recursively "${btrfsMount}/$i"
            done
            btrfs subvolume delete "$1"
          }

          for i in $(find ${oldRootsPath}/ -maxdepth 1 -mtime +30 2>/dev/null || true); do
            delete_subvolume_recursively "$i"
          done

          btrfs subvolume snapshot ${blankRootPath} ${rootPath}

          umount ${btrfsMount}
        '';
      };
    })
  ];
}
