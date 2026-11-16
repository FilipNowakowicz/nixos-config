_: {
  # ── Gaming ──────────────────────────────────────────────────────────────────
  # Steam for native-Linux titles such as CS2. programs.steam also enables
  # hardware.graphics.enable32Bit, which the 32-bit Steam client needs.
  #
  # The session pins every app to the Intel iGPU (modules/nixos/hardware/
  # nvidia-prime.nix), so games have to opt into the GTX 1650 Ti themselves.
  # Set this as the game's Steam launch option:
  #   gamemoderun nvidia-offload %command%
  #
  # The Steam library lives under ~/.local/share/Steam on the persistent /home
  # volume, so impermanence does not need any extra paths.
  programs = {
    steam.enable = true;
    # CPU governor / scheduler tweaks while a game runs, via `gamemoderun`.
    gamemode.enable = true;
  };
}
