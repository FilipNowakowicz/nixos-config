# System services that don't belong to a larger concern: firmware updates,
# filesystem scrubbing, SSH, and failure notifications.
{ config, ... }:
{
  services = {
    # Enabled by default with a graphical session, and pulls in about 645 MiB
    # of mbrola voices. Nothing here uses system text-to-speech.
    speechd.enable = false;

    fwupd.enable = true;
    btrfs.autoScrub = {
      enable = true;
      fileSystems = [ "/" ];
    };

    openssh = {
      enable = true;
      openFirewall = false; # Accessible via Tailscale only
      hostKeys = [
        {
          path = "/etc/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
      ];
    };

    # A system unit has no display, so without this a failure only reaches
    # the journal.
    systemd-failure-notify = {
      enable = true;
      webhookUrlFile = config.sops.secrets.failure_webhook_url.path;
      services = [
        # "prometheus"
        "btrbk-local"
        "restic-backups-local"
        "restic-check-local"
        "thermald"
        "power-profiles-daemon"
      ];
    };

    # fwupd: writes firmware to hardware and loads kernel modules.
    # Skip ProtectSystem (firmware writes), PrivateDevices (/dev access),
    # ProtectKernelModules/Tunables (capsule loading), ProtectClock (EFI time),
    # MemoryDenyWriteExecute (plugin loading).
    # Relaxing SystemCallFilter preserves fwupd's upstream custom allowlist
    # (@basic-io @file-system @io-event ... ioctl uname fadvise64 ...), which
    # is narrower than @system-service; appending @system-service would widen
    # it.
    hardened.fwupd = {
      relaxBase = [
        "PrivateDevices"
        "ProtectSystem"
        "ProtectKernelTunables"
        "ProtectKernelModules"
        "ProtectClock"
        "MemoryDenyWriteExecute"
        "SystemCallFilter"
        "ProcSubset"
      ];
      extraConfig = {
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        # fwupd 2.1.4 added fwupd-refresh.service, which runs as a dedicated
        # fwupd-refresh user with StateDirectory=fwupd. systemd therefore chowns
        # /var/lib/fwupd to fwupd-refresh:fwupd-refresh (0755). The root-run
        # fwupd.service daemon then needs CAP_DAC_OVERRIDE to write into a
        # directory it no longer owns, plus CAP_CHOWN/CAP_FOWNER to set
        # ownership/permissions on the keyring/pki files it creates there. The
        # hardening baseline strips all capabilities by default, so re-grant
        # exactly these three (otherwise fwupd.service fails -> SystemdUnitFailed).
        CapabilityBoundingSet = [
          "CAP_DAC_OVERRIDE"
          "CAP_CHOWN"
          "CAP_FOWNER"
        ];
      };
    };
  };
}
