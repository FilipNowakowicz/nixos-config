{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.profiles.impermanence.rollbackRoot;
  # main is the only impermanent host and its disko layout fixes these names.
  # They were options once; no host ever set them.
  device = "/dev/mapper/cryptroot";
  cryptsetupUnit = "systemd-cryptsetup@cryptroot.service";
  rootSubvol = "@root";
  blankSubvol = "@root-blank";
  btrfsMount = "/btrfs_tmp";
  rootPath = "${btrfsMount}/${rootSubvol}";
  blankRootPath = "${btrfsMount}/${blankSubvol}";
  oldRootsPath = "${btrfsMount}/old_roots";
in
{
  options.profiles.impermanence.rollbackRoot = {
    enable = lib.mkEnableOption ''
      rolling the impermanent root subvolume back to a blank snapshot during initrd boot
    '';
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
        description = "Roll ${rootSubvol} back to the empty ${blankSubvol} btrfs snapshot";
        wantedBy = [ "initrd.target" ];
        after = [ cryptsetupUnit ];
        before = [ "sysroot.mount" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig.Type = "oneshot";
        script = ''
          set -euo pipefail

          mkdir -p ${btrfsMount}
          mount -t btrfs -o subvol=/ ${device} ${btrfsMount}

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

          for i in $(find ${oldRootsPath}/ -maxdepth 1 -mtime +7 2>/dev/null || true); do
            delete_subvolume_recursively "$i"
          done

          btrfs subvolume snapshot ${blankRootPath} ${rootPath}

          umount ${btrfsMount}
        '';
      };
    })
  ];
}
