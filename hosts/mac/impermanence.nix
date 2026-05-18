{ inputs, pkgs, ... }:
{
  imports = [
    inputs.impermanence.nixosModules.impermanence
    ../../modules/nixos/profiles/impermanence-base.nix
  ];

  # /nix is its own btrfs subvolume; stage 1 must mount it before stage 2
  # init (which lives in /nix/store) can exec. /persist is already marked
  # neededForBoot in impermanence-base.nix.
  fileSystems."/nix".neededForBoot = true;

  # Ephemeral root: @root is rolled back to @root-blank on every boot. Same
  # pattern as main; old roots are moved to /old_roots/<ts> for 30 days. See
  # hosts/main/impermanence.nix for the rationale and recovery walkthrough.
  #
  # Companion-class persistence: this list starts deliberately coarse with
  # blanket /var/lib + /var/cache because canonical state lives on `main` and
  # gets to mac via Syncthing. Tighten later by enumerating individual
  # services if disk pressure or compliance ever demands it.
  environment.persistence."/persist".directories = [
    "/var/lib"
    "/var/cache"
    "/etc/NetworkManager/system-connections"
    "/root"
    # systemd state that affects boot-time behavior rather than runtime:
    "/var/lib/systemd/timers"
    "/var/lib/systemd/backlight"
    "/var/lib/systemd/rfkill"
  ];

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
        for i in $(btrfs subvolume list -o "$1" | cut -f 9 -d ' '); do
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
}
