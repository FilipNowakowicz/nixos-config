{
  # The Apple-branded NVMe in a 2017 MacBook Air is the only NVMe device on the
  # bus, so `/dev/nvme0n1` is stable across boots. Once the host is alive,
  # replace this with `/dev/disk/by-id/nvme-...` and rebuild for resilience
  # against future hardware additions (USB NVMe enclosures, etc).
  disko.devices = {
    disk.mac = {
      type = "disk";
      device = "/dev/nvme0n1";
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
              # No TPM2 on a 2017 MacBook Air — LUKS unlock is passphrase-only
              # at the bootloader prompt. Keep the passphrase in your password
              # manager; there is no initrd SSH fallback configured.
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
