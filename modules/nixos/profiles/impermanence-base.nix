{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.profiles.impermanence.rollbackRoot;
in
{
  options.profiles.impermanence.rollbackRoot.enable = lib.mkEnableOption ''
    rolling @root back to @root-blank during initrd boot
  '';

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
      ];

      boot.initrd.systemd.services.rollback-root = {
        description = "Roll @root back to the empty @root-blank btrfs snapshot";
        wantedBy = [ "initrd.target" ];
        after = [ "systemd-cryptsetup@cryptroot.service" ];
        before = [ "sysroot.mount" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig.Type = "oneshot";
        script = ''
          set -euo pipefail

          mkdir -p /btrfs_tmp
          mount -t btrfs -o subvol=/ /dev/mapper/cryptroot /btrfs_tmp

          if [ -e /btrfs_tmp/@root ]; then
            timestamp=$(date --date="@$(stat -c %Y /btrfs_tmp/@root)" "+%Y-%m-%d_%H:%M:%S")
            mkdir -p /btrfs_tmp/old_roots
            mv /btrfs_tmp/@root "/btrfs_tmp/old_roots/$timestamp"
          fi

          delete_subvolume_recursively() {
            IFS=$'\n'
            for i in $(btrfs subvolume list -o "$1" | sed -n 's/.* path //p'); do
              delete_subvolume_recursively "/btrfs_tmp/$i"
            done
            btrfs subvolume delete "$1"
          }

          for i in $(find /btrfs_tmp/old_roots/ -maxdepth 1 -mtime +30 2>/dev/null || true); do
            delete_subvolume_recursively "$i"
          done

          btrfs subvolume snapshot /btrfs_tmp/@root-blank /btrfs_tmp/@root

          umount /btrfs_tmp
        '';
      };
    })
  ];
}
