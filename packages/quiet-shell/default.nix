{
  lib,
  stdenvNoCC,
  makeWrapper,
  quickshell,
  python3,
  bluez,
  brightnessctl,
  hyprlock,
  mullvad-vpn,
  networkmanager,
  pipewire,
  playerctl,
  power-profiles-daemon,
  procps,
  systemd,
  tailscale,
  util-linux,
  wireplumber,
  wlsunset,
}:

let
  # status.py and Sys.qml call these by name, so the shell behaves the same however
  # it is launched. Tests put fakes first on PATH instead of a separate test mode.
  runtime = [
    python3
    bluez
    brightnessctl
    hyprlock
    mullvad-vpn
    networkmanager
    pipewire
    playerctl
    power-profiles-daemon
    procps
    systemd
    tailscale
    util-linux
    wireplumber
    wlsunset
  ];
in
stdenvNoCC.mkDerivation {
  pname = "quiet-shell";
  version = "0.1.0";
  src = ./shell;
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/quiet-shell $out/bin
    cp -r . $out/share/quiet-shell
    makeWrapper ${quickshell}/bin/qs $out/bin/quiet-shell \
      --add-flags "-p $out/share/quiet-shell" \
      --suffix PATH : ${lib.makeBinPath runtime}
    makeWrapper ${quickshell}/bin/qs $out/bin/quiet-shell-ipc \
      --add-flags "ipc -p $out/share/quiet-shell call shell"
    runHook postInstall
  '';

  meta = {
    description = "Quiet, auto-hiding desktop shell for Hyprland";
    mainProgram = "quiet-shell";
    platforms = lib.platforms.linux;
  };
}
