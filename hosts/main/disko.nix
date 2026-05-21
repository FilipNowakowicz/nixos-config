{ hostMeta, ... }:
{
  disko.devices = {
    disk.main = {
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
                "main-boot"
              ];
            };
          };
          luks = {
            size = "100%";
            content = {
              type = "luks";
              name = "cryptroot";
              settings.crypttabExtraOpts = [ "tpm2-device=auto" ];
              content = {
                type = "btrfs";
                extraArgs = [
                  "-f"
                  "-L"
                  "main-root"
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
                  "/@root-blank" = { };
                };
              };
            };
          };
        };
      };
    };
  };
}
