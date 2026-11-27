# Secure Boot, kernel parameters, and the initrd SSH unlock path.
{
  lib,
  pkgs,
  ...
}:
{
  environment.systemPackages = with pkgs; [
    efibootmgr
    sbctl
  ];

  boot = {
    # Lanzaboote (Secure Boot)
    loader.systemd-boot.enable = lib.mkForce false;
    loader.systemd-boot.configurationLimit = 5;
    lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
    };

    # IOMMU protection — blocks Thunderbolt/PCIe DMA attacks
    kernelParams = [
      # igfx_off leaves only the integrated GPU untranslated. While i915 takes
      # over the firmware framebuffer the iGPU still scans out memory that has
      # no IOMMU mapping; the resulting DMAR faults can reach i915's pipe-fault
      # IRQ handler before its planes exist, and handle_plane_fault NULL-derefs
      # into a boot panic (6.18.64, 2026-11-24). The iGPU is soldered on, not a
      # DMA attack surface; Thunderbolt/PCIe devices and the dGPU stay behind
      # the IOMMU. Drop igfx_off once upstream i915 tolerates the fault.
      "intel_iommu=on,igfx_off"
      "iommu=force"
      "mem_sleep_default=deep"
      # This Yoga 9 15IMH5 exposes DYTC v4, which ideapad_laptop gates behind an
      # opt-in ("DYTC_VERSION 4 support may not work"). Without it there is no
      # ACPI platform_profile, so power-profiles-daemon only tunes intel_pstate
      # EPP and never switches the EC's intelligent-cooling mode (fan curve and
      # PL1/PL2). Opting in lets power-saver/balanced/performance reach firmware.
      "ideapad_laptop.allow_v4_dytc=Y"
    ];

    initrd = {
      systemd = {
        # Tear down all non-loopback interfaces before transitioning to stage 2.
        # Ensures port 2222 stops being reachable the moment stage 1 is done,
        # before stage 2's firewall loads. Guards against future misconfiguration
        # (e.g. if WiFi support were added to initrd later).
        services.flush-network-before-stage2 = {
          description = "Tear down initrd network before transitioning to stage 2";
          before = [ "initrd-cleanup.service" ];
          wantedBy = [ "initrd.target" ];
          unitConfig.DefaultDependencies = false;
          serviceConfig = {
            Type = "oneshot";
          };
          script = ''
            for iface in /sys/class/net/*; do
              iface=$(basename "$iface")
              [ "$iface" = "lo" ] && continue
              ${pkgs.iproute2}/bin/ip link set dev "$iface" down 2>/dev/null || true
              ${pkgs.iproute2}/bin/ip addr flush dev "$iface" 2>/dev/null || true
            done
          '';
        };
      };

      # Initrd SSH — fallback LUKS unlock when TPM2 fails.
      # Recovery requires a USB Ethernet dongle; WiFi is not available in stage 1.
      # Port 2222 is therefore NOT exposed on WiFi (including public WiFi).
      # flush-network-before-stage2 tears down the interface before stage 2 starts.
      network = {
        enable = true;
        ssh = {
          enable = true;
          port = 2222;
          authorizedKeys = import ../../lib/recovery-pubkeys.nix;
          hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
        };
      };
      secrets = {
        "/etc/secrets/initrd/ssh_host_ed25519_key" = lib.mkForce "/run/secrets/initrd_ssh_host_ed25519_key";
      };
    };
  };

  systemd.services = {
    # The initrd runs systemd-networkd for SSH unlock (boot.initrd.network
    # below), and its state file survives switch-root in /run reading
    # OPER_STATE=off. Stage 2 uses NetworkManager, so nothing ever updates
    # it, and systemd-timesyncd took the machine for offline forever: it
    # never contacted a server. Without the file it counts as online.
    clear-initrd-netif-state = {
      description = "Forget the initrd's systemd-networkd state";
      wantedBy = [ "sysinit.target" ];
      before = [
        "sysinit.target"
        "systemd-timesyncd.service"
      ];
      unitConfig.DefaultDependencies = false;
      serviceConfig.Type = "oneshot";
      script = "rm -rf /run/systemd/netif";
    };
  };
}
