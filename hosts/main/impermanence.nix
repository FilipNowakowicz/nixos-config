{ config, inputs, ... }:
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
  # the btrfs top level and kept for 7 days for forensic recovery; mount
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
    "/var/lib/tudor" # fingerprint sensor pairing data
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
    "/var/lib/systemd/pstore" # kernel panic dumps systemd-pstore archives from EFI on the next boot
    "/var/lib/runtime-timezone" # timezone chosen at runtime (profiles.runtimeTimezone)
    "/var/lib/libvirt" # libvirt VM images and domain definitions (Whonix KVM)
  ];

  # systemd-creds host key. libvirt encrypts its secrets key with it
  # (virt-secret-init-encryption writes /var/lib/libvirt/secrets/), so a fresh
  # key on every rollback left that persisted file undecryptable and libvirtd
  # failed to start.
  environment.persistence."/persist".files = [ "/var/lib/systemd/credential.secret" ];

  # impermanence bind-mounts a file only when it already exists in /persist;
  # otherwise it leaves a symlink, which systemd-creds refuses (ELOOP). Create
  # the key there first. This is a stage-2 unit, not an activation script:
  # activation runs in the initrd, where systemd-creds will not make a host key.
  systemd.services.credential-host-secret =
    let
      hostKey = "/persist/var/lib/systemd/credential.secret";
    in
    {
      description = "Create the persisted systemd-creds host key";
      wantedBy = [ "local-fs.target" ];
      before = [ "persist-persist-var-lib-systemd-credential.secret.service" ];
      unitConfig = {
        DefaultDependencies = false;
        RequiresMountsFor = [ "/persist" ];
        ConditionPathExists = "!${hostKey}";
      };
      environment.SYSTEMD_CREDENTIAL_SECRET = hostKey;
      serviceConfig.Type = "oneshot";
      script = ''
        mkdir -p "$(dirname "$SYSTEMD_CREDENTIAL_SECRET")"
        ${config.systemd.package}/bin/systemd-creds setup
      '';
    };
}
