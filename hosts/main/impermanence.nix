{ inputs, ... }:
{
  imports = [
    inputs.impermanence.nixosModules.impermanence
    ../../modules/nixos/profiles/impermanence-base.nix
  ];

  # /nix is its own btrfs subvolume; stage 1 must mount it before stage 2
  # init (which lives in /nix/store) can exec. /persist is already marked
  # neededForBoot in impermanence-base.nix.
  fileSystems."/nix".neededForBoot = true;
  profiles.impermanence.rollbackRoot.enable = true;

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
    "/var/cache/mullvad-vpn" # Mullvad relay/API cache (persisted across reboots but not backed up to B2)
    # systemd state that affects boot-time behavior, not just runtime:
    "/var/lib/systemd/timers" # Persistent=true timer catchup (restic-check-local)
    "/var/lib/systemd/backlight" # restore screen brightness across reboots
    "/var/lib/systemd/rfkill" # restore Wi-Fi / Bluetooth block state
    "/var/lib/libvirt" # libvirt VM images and domain definitions (Whonix KVM)
  ];

}
