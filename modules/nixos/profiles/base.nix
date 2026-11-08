{
  lib,
  pkgs,
  ...
}:
{
  zramSwap.enable = true;

  # None of the current hosts use ZFS for root import. Set the upcoming 26.11
  # default explicitly across the fleet to avoid evaluation-time warnings.
  boot.zfs.forceImportRoot = lib.mkDefault false;

  # ── Nix ────────────────────────────────────────────────────────────────────
  nixpkgs.config.allowUnfree = true;
  nix = {
    settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };

    # Hardlink duplicate store paths once a week instead of after every build.
    # auto-optimise-store taxes every nix build with a synchronous dedup pass;
    # the timer-driven variant runs out-of-band and matches the gc cadence.
    optimise = {
      automatic = true;
      dates = [ "weekly" ];
    };
  };

  systemd.services.nix-daemon.serviceConfig = {
    # Nix builds can legitimately use all available CPU. Keep them responsive
    # enough for manual work, but bias scheduling away from interactive desktop
    # processes so transient evaluations/builds do not dominate thermals.
    CPUWeight = 50;
    Nice = 10;
    IOWeight = 50;
    IOSchedulingClass = "best-effort";
    IOSchedulingPriority = lib.mkForce 6;
  };

  # ── Localization ───────────────────────────────────────────────────────────
  time.timeZone = lib.mkDefault "Europe/Warsaw";
  i18n.defaultLocale = lib.mkDefault "en_GB.UTF-8";
  console.keyMap = lib.mkDefault "dvorak";

  # ── Shell ───────────────────────────────────────────────────────────────────
  programs.zsh.enable = lib.mkDefault true;
  users.defaultUserShell = pkgs.zsh;

  # ── System Packages ────────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    curl
    pciutils
    rsync
    usbutils
    wget
  ];
}
