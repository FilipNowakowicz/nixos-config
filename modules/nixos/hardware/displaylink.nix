{
  config,
  lib,
  pkgs,
  ...
}:
# ── DisplayLink (USB display-over-protocol) ──────────────────────────────────
#
# DisplayLink is NOT a real DRM connector. The dock renders nothing itself: the
# proprietary `DisplayLinkManager` userspace daemon (the unfree `displaylink`
# package) scrapes frames from a virtual GPU exposed by the `evdi` kernel module
# and pushes them over USB. So three things must line up: the evdi module, the
# DisplayLinkManager service, and a compositor willing to drive the evdi card.
#
# Two host-specific collisions are handled here; a third is manual:
#
#   1. CI purity — `pkgs.displaylink` is a `requireFile` of an unfree blob that
#      cannot be fetched in CI (see the runbook for the one-time prefetch). We
#      gate the whole driver behind `!profiles.ci` so `main-ci` — the closure
#      `merge-gate` actually builds — never references the blob. This mirrors the
#      existing fprintd gating in hosts/main/default.nix.
#
#   2. GPU pinning — Hyprland's aquamarine backend only opens DRM nodes listed in
#      AQ_DRM_DEVICES, which modules/nixos/hardware/nvidia-prime.nix pins to the
#      Intel iGPU alone. We append the evdi card so Hyprland can drive the
#      DisplayLink output (Intel stays primary/render; evdi is an output sink).
#
#   3. USBGuard (MANUAL, not done here) — hosts/main/default.nix default-rejects
#      all USB. The dock enumerates as USB and is blocked until you add an allow
#      rule for its real VID:PID/serial. See .claude/main/displaylink.md.
#
# Upstream nixos/modules/hardware/video/displaylink.nix activates whenever
# "displaylink" is in services.xserver.videoDrivers: it loads evdi, ships the
# udev rules, defines the `dlm` (DisplayLinkManager) service, and wires
# suspend/resume hooks. We only supplement what it leaves out for a Wayland,
# greetd-driven, Intel-pinned session.
let
  enable = !config.profiles.ci;
in
{
  config = lib.mkIf enable {
    # The pinned nixpkgs ships a displaylink package that takes `linuxPackages`
    # (to find evdi), but its NixOS module still calls
    # `pkgs.displaylink.override { inherit evdi; }`, which fails evaluation with
    # "called with unexpected argument 'evdi'". Newer nixpkgs master passes
    # `linuxPackages = config.boot.kernelPackages` instead. Accept the old call
    # and bind the package to our (evdi-patched) kernelPackages. Remove once the
    # locked nixpkgs includes the module fix.
    nixpkgs.overlays = [
      (_: previous: {
        displaylink = lib.makeOverridable (
          # Accepts (and ignores) the legacy `evdi` argument.
          _: previous.displaylink.override { linuxPackages = config.boot.kernelPackages; }
        ) { };
      })
    ];

    # Work around nixpkgs#575192: copying evdi.ko directly skips Kbuild's
    # certificate generation, so the kernel module aggregator fails. Remove
    # this override once upstream evdi installs through modules_install.
    boot.kernelPackages = lib.mkDefault (
      pkgs.linuxPackages.extend (
        _: previous: {
          evdi = previous.evdi.overrideAttrs (old: {
            installPhase = ''
              runHook preInstall
              make -C ${config.boot.kernelPackages.kernel.dev}/lib/modules/${config.boot.kernelPackages.kernel.modDirVersion}/build \
                ${lib.escapeShellArgs (lib.filter (flag: flag != "module") old.makeFlags)} M="$PWD/module" \
                INSTALL_MOD_PATH="$out" INSTALL_MOD_DIR=kernel/drivers/gpu/drm/evdi \
                DEPMOD=true modules_install
              install -Dm755 library/libevdi.so "$out/lib/libevdi.so"
              runHook postInstall
            '';
          });
        }
      )
    );

    # videoDrivers is a merging list; this appends to nvidia-prime's [ "nvidia" ]
    # rather than replacing it. "displaylink" is the activation key for the
    # upstream module above; "modesetting" backs the evdi output.
    services.xserver.videoDrivers = [
      "displaylink"
      "modesetting"
    ];

    # No `wantedBy` for `dlm`: the upstream package's udev rule starts it via
    # SYSTEMD_WANTS when a DisplayLink interface (VID 17e9) appears, including
    # at coldplug and after USBGuard authorizes the dock. Starting it at boot
    # kept DisplayLinkManager polling (~2% of a core) with no dock attached.

    # Stable, colon-free symlink for the evdi virtual card (same pattern as the
    # intel-igpu rule in nvidia-prime.nix) so AQ_DRM_DEVICES doesn't depend on
    # cardN enumeration order.
    services.udev.extraRules = ''
      SUBSYSTEM=="drm", KERNEL=="card*", SUBSYSTEMS=="platform", DRIVERS=="evdi", SYMLINK+="dri/displaylink"
    '';

    # mkForce overrides the Intel-only pin set in nvidia-prime.nix:90. Intel MUST
    # stay first (primary render device); evdi is appended as a secondary output.
    # NOTE: if Hyprland ever refuses to start with NO dock attached (a missing
    # secondary device in the list), drop back to the intel-only value — see the
    # runbook's "Hyprland won't start" note.
    environment.sessionVariables.AQ_DRM_DEVICES = lib.mkForce "/dev/dri/intel-igpu:/dev/dri/displaylink";
  };
}
