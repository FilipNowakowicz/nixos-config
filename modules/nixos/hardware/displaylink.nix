{ config, lib, ... }:
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
    # videoDrivers is a merging list; this appends to nvidia-prime's [ "nvidia" ]
    # rather than replacing it. "displaylink" is the activation key for the
    # upstream module above; "modesetting" backs the evdi output.
    services.xserver.videoDrivers = [
      "displaylink"
      "modesetting"
    ];

    # Upstream defines `dlm` with no `wantedBy`, expecting an X11 display-manager
    # to pull it in. We run greetd + Hyprland (no display-manager.service), so
    # start DisplayLinkManager explicitly or no frames ever leave the daemon.
    systemd.services.dlm.wantedBy = [ "multi-user.target" ];

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
