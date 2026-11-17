# Boot and disk drivers for a GCE VM booting UEFI, shared by homeserver-gcp and
# gcp-builder through profiles/gce-server.nix. fileSystems and swap come from
# each host's disko.nix.
#
# Hand-maintained, not generated: the virtio set is what every GCE machine type
# exposes. Revalidate with `nixos-generate-config --show-hardware-config` on a
# host if a machine-type change (e.g. to NVMe-only) stops it booting.
# Last reviewed: 2026-11-17
{ modulesPath, ... }:
{
  imports = [
    "${modulesPath}/installer/scan/not-detected.nix"
  ];

  boot = {
    initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_blk"
      "virtio_scsi"
      "sd_mod"
    ];
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
  };
}
