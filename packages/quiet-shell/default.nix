{
  lib,
  stdenvNoCC,
  makeWrapper,
  quickshell,
  python3,
  bluez,
  brightnessctl,
  cliphist,
  curl,
  fd,
  grim,
  hyprlock,
  khal,
  mullvad-vpn,
  networkmanager,
  networkmanagerapplet,
  pipewire,
  playerctl,
  power-profiles-daemon,
  procps,
  slurp,
  systemd,
  tailscale,
  tesseract,
  tzdata,
  util-linux,
  wireplumber,
  wl-clipboard,
  wlsunset,
  xdg-utils,
}:

let
  # Text capture reads English and Polish; by default tesseract bundles every language.
  ocr = tesseract.override {
    enableLanguages = [
      "eng"
      "pol"
    ];
  };
  # status.py and Sys.qml call these by name, so the shell behaves the same however
  # it is launched. Tests put fakes first on PATH instead of a separate test mode.
  runtime = [
    python3
    bluez
    brightnessctl
    cliphist
    curl
    fd
    grim
    hyprlock
    khal
    mullvad-vpn
    networkmanager
    networkmanagerapplet
    pipewire
    playerctl
    power-profiles-daemon
    procps
    slurp
    systemd
    tailscale
    ocr
    util-linux
    wireplumber
    wl-clipboard
    wlsunset
    xdg-utils
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
      --set QUIET_ZONE_TAB ${tzdata}/share/zoneinfo/zone1970.tab \
      --suffix PATH : ${lib.makeBinPath runtime}:$out/bin
    makeWrapper ${python3}/bin/python3 $out/bin/quiet-buds \
      --add-flags "$out/share/quiet-shell/scripts/buds.py" \
      --suffix PATH : ${lib.makeBinPath [ bluez ]}
    makeWrapper ${quickshell}/bin/qs $out/bin/quiet-shell-ipc \
      --add-flags "ipc -p $out/share/quiet-shell call shell"
    runHook postInstall
  '';

  # Tests run the helper scripts with the same tools the shell gives them.
  passthru = { inherit runtime; };

  meta = {
    description = "Quiet, auto-hiding desktop shell for Hyprland";
    mainProgram = "quiet-shell";
    platforms = lib.platforms.linux;
  };
}
