{ pkgs, ... }:
{
  # ── Identity ────────────────────────────────────────────────────────────
  # Fake hostname — never copy a real machine's identity into a public example.
  networking.hostName = "workstation-example";
  system.stateVersion = "26.05";

  # ── Disks ───────────────────────────────────────────────────────────────
  # Deliberately NOT wired to a real `/dev/disk/by-id/*` — a copyable example
  # must never leak a real machine's hardware identifiers. Point this at your
  # own disko/hardware-configuration when adapting the pattern for real use.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  # A placeholder bootloader target — same `by-label` convention as the
  # filesystem above — so `system.build.toplevel` evaluates to a buildable
  # derivation (NixOS asserts a GRUB target device otherwise). Point this at
  # your own boot disk when adapting the pattern for real use.
  boot.loader.grub.devices = [ "/dev/disk/by-label/nixos" ];

  # ── Users ───────────────────────────────────────────────────────────────
  users.users.demo = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };

  # ── Layering note ───────────────────────────────────────────────────────
  # `profiles.desktop` and `profiles.security` are imported as public
  # `nixosModules.*` outputs at the flake level (see ../../flake.nix). This
  # file only carries host-local facts: identity, disks, and users — exactly
  # the boundary the layering pattern relies on.

  environment.systemPackages = [ pkgs.git ];
}
