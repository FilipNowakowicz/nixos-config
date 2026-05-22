{
  inputs,
  lib,
  pkgs,
  self,
  ...
}:
let
  configurationRevision = self.dirtyShortRev or self.shortRev or self.dirtyRev or self.rev or null;
in
{
  zramSwap.enable = true;

  system.configurationRevision = lib.mkDefault configurationRevision;

  system.activationScripts.exportSystemMetadata.text = ''
    install -d -m 0755 /var/lib/node-exporter-textfiles
    activated_at="$(${pkgs.coreutils}/bin/date +%s)"
    tmp="/var/lib/node-exporter-textfiles/system_metadata.prom.tmp"

    cat >"$tmp" <<EOF
    nixos_system_activated_at_seconds $activated_at
    EOF

  ''
  + lib.optionalString (configurationRevision != null) ''
    cat >>"$tmp" <<EOF
    nixos_system_revision_info{revision="${configurationRevision}"} 1
    EOF
  ''
  + ''
    chmod 0644 "$tmp"
    mv "$tmp" /var/lib/node-exporter-textfiles/system_metadata.prom
  '';

  # None of the current hosts use ZFS for root import. Set the upcoming 26.11
  # default explicitly across the fleet to avoid evaluation-time warnings.
  boot.zfs.forceImportRoot = lib.mkDefault false;

  # ── Nix ────────────────────────────────────────────────────────────────────
  nixpkgs.config.allowUnfree = true;
  nix = {
    registry.nixpkgs.flake = inputs.nixpkgs;

    # Keep legacy nixpkgs lookups aligned with the flake-pinned registry entry.
    nixPath = [ "nixpkgs=flake:nixpkgs" ];

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
