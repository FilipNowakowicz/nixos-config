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

  # Ephemeral root: @root is rolled back to @root-blank (an empty read-only
  # btrfs snapshot at the filesystem top-level) on every boot. Anything not
  # bind-mounted from /persist below — or living on /nix, /home, /persist —
  # is erased on reboot. The previous @root is moved to /old_roots/<ts> at
  # the btrfs top level and kept for 30 days for forensic recovery; mount
  # `-o subvol=/ /dev/mapper/cryptroot` somewhere to browse.
  #
  # Adding a new persistent path:
  #   sudo cp -a /var/lib/<thing> /persist/var/lib/   # snapshot live state
  #   add the path to the directories list below
  #   sudo nh os switch --hostname main .             # bind mount takes effect
  # Skip the cp and the bind mount lands on an empty dir; the service loses
  # its state at the next reboot's rollback.
  environment.persistence."/persist".directories = [
    "/var/lib/sbctl" # Lanzaboote / Secure Boot PKI
    "/var/lib/tailscale" # tailnet node identity + peers
    "/var/lib/bluetooth" # Bluetooth pairings
    "/var/lib/fprint" # fingerprint enrollments
    "/var/lib/usbguard" # USBGuard rule hashes
    "/var/lib/fail2ban" # banned-IP database (resets to empty without this)
    "/var/cache/tuigreet" # tuigreet --remember last-user cache
    "/var/cache/restic-backups-local" # restic index/pack cache; avoid B2 re-download after each rollback
    "/etc/NetworkManager/system-connections" # saved Wi-Fi / VPN profiles
    "/etc/mullvad-vpn" # Mullvad account + device + settings
    "/var/cache/mullvad-vpn" # Mullvad relay/API cache
    # systemd state that affects boot-time behavior, not just runtime:
    "/var/lib/systemd/timers" # Persistent=true timer catchup (restic-check-local)
    "/var/lib/systemd/backlight" # restore screen brightness across reboots
    "/var/lib/systemd/rfkill" # restore Wi-Fi / Bluetooth block state
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
