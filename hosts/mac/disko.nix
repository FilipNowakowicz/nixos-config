{ hostMeta, ... }:
{
  # The Apple-branded SSD in this MacBook Air is exposed by the installer as an
  # ATA disk, not NVMe. Use the stable by-id path so USB installer/device order
  # cannot redirect disko to the wrong disk.
  disko.devices = {
    disk.mac = {
      type = "disk";
      device = hostMeta.hardware.diskById;
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "512M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [
                "umask=0077"
                "fmask=0077"
                "dmask=0077"
              ];
              extraArgs = [
                "-n"
                "mac-boot"
              ];
            };
          };
          luks = {
            size = "100%";
            content = {
              type = "luks";
              name = "cryptroot";
              # No TPM2 on a 2017 MacBook Air. While the host stays at home,
              # initrd unlock uses a sops-managed keyfile slot (see the
              # `boot.initrd` block in default.nix); the original passphrase
              # remains valid as fallback. Plan to revert to passphrase-only
              # (or FIDO2) before the laptop travels.
              content = {
                type = "btrfs";
                extraArgs = [
                  "-f"
                  "-L"
                  "mac-root"
                ];
                subvolumes = {
                  "/@root" = {
                    mountpoint = "/";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                      "discard=async"
                    ];
                  };
                  "/@root-blank" = { };
                  "/@home" = {
                    mountpoint = "/home";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                      "discard=async"
                    ];
                  };
                  "/@nix" = {
                    mountpoint = "/nix";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                      "discard=async"
                    ];
                  };
                  "/@persist" = {
                    mountpoint = "/persist";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                      "discard=async"
                    ];
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
