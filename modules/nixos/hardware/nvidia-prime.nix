{ config, pkgs, ... }:
let
  mesaEglVendor = "${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json";
  intelVulkanIcds = "${pkgs.mesa}/share/vulkan/icd.d/intel_icd.x86_64.json:${pkgs.mesa}/share/vulkan/icd.d/intel_hasvk_icd.x86_64.json";
in
{
  # ── Graphics ────────────────────────────────────────────────────────────────
  # NVIDIA GPU with Intel iGPU PRIME offload
  #
  # Hyprland renders on the Intel iGPU by default. The NVIDIA GPU is available
  # on demand via `nvidia-offload <cmd>`.

  hardware = {
    # Needed for both Intel (Mesa) and NVIDIA (VA-API consumers, Hyprland, etc.)
    graphics = {
      enable = true;
      extraPackages = with pkgs; [
        # Firefox's VA-API self-test fails unless the Intel media driver is exposed
        # via /run/opengl-driver/lib/dri alongside the Mesa/NVIDIA stack.
        intel-media-driver
      ];
    };

    nvidia = {
      modesetting.enable = true; # required for Wayland / Hyprland
      # Keep runtime power gating focused on PRIME offload. The broader NVIDIA
      # power-management option enables suspend/hibernate video-memory
      # preservation, which keeps this offload-only dGPU active instead of
      # allowing fine-grained Runtime D3 when idle.
      powerManagement.enable = false;
      powerManagement.finegrained = true; # Turing+ (TU117M): full dGPU power-gate when idle
      open = false; # use proprietary kernel module
      nvidiaSettings = true;
      package = config.boot.kernelPackages.nvidiaPackages.stable;

      # PRIME offload — Hyprland renders on the Intel iGPU by default.
      # The NVIDIA GPU is available on demand via `nvidia-offload <cmd>`.
      #
      # Verify bus IDs before the first install:
      #   lspci | grep -E "VGA|3D"
      # Format expected by NixOS: "PCI:<bus>:<slot>:<function>" (decimal)
      prime = {
        offload = {
          enable = true;
          # Provide our own wrapper below so it can undo the default Mesa/Intel
          # pins before opting an application into the NVIDIA GPU.
          enableOffloadCmd = false;
        };
        intelBusId = "PCI:0:2:0";
        nvidiaBusId = "PCI:1:0:0";
      };
    };
  };

  # Loads the NVIDIA kernel module and wires up the Xorg/DRM stack
  services.xserver.videoDrivers = [ "nvidia" ];

  # ── Stable DRM symlink ──────────────────────────────────────────────────────
  # AQ_DRM_DEVICES is colon-delimited, so /dev/dri/by-path/pci-0000:00:02.0-card
  # can't be used directly. This udev rule creates a stable, colon-free symlink
  # for the Intel iGPU (PCI 0000:00:02.0) that survives kernel updates.
  services.udev.extraRules = ''
    SUBSYSTEM=="drm", KERNEL=="card*", KERNELS=="0000:00:02.0", SYMLINK+="dri/intel-igpu"
  '';

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "nvidia-offload" ''
      unset __EGL_VENDOR_LIBRARY_FILENAMES
      unset VK_DRIVER_FILES
      unset VK_ICD_FILENAMES
      export __NV_PRIME_RENDER_OFFLOAD=1
      export __NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0
      export __GLX_VENDOR_LIBRARY_NAME=nvidia
      export __VK_LAYER_NV_optimus=NVIDIA_only
      exec "$@"
    '')
  ];

  # ── Intel iGPU / Wayland env vars ──────────────────────────────────────────
  # Pins the normal session to the Intel iGPU. NVIDIA is available on-demand via
  # nvidia-offload, but passive EGL/Vulkan vendor probing should not wake it.
  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1"; # Electron apps: use Wayland backend
    LIBVA_DRIVER_NAME = "iHD"; # VA-API → Intel Media Driver
    __GLX_VENDOR_LIBRARY_NAME = "mesa"; # GLX → Mesa (Intel) by default
    __EGL_VENDOR_LIBRARY_FILENAMES = mesaEglVendor;
    VK_DRIVER_FILES = intelVulkanIcds;
    VK_ICD_FILENAMES = intelVulkanIcds;
    # Pins Hyprland's primary GPU to the Intel iGPU via a stable udev symlink.
    AQ_DRM_DEVICES = "/dev/dri/intel-igpu";
  };
}
