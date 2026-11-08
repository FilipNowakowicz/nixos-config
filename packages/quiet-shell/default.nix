{
  lib,
  stdenvNoCC,
  makeWrapper,
  writers,
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
  # Directories for commands the desktop provides. They come last on PATH, so the
  # session and test fakes still win.
  extraPath ? [ ],
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
  # No input method runs here, and Qt's text-input support is the likely reason the
  # letter typed right after Ctrl+Backspace in Spotlight went missing.
  textInput = [
    "zwp_text_input_manager_v1"
    "zwp_text_input_manager_v2"
    "zwp_text_input_manager_v3"
    "qt_text_input_method_manager_v1"
  ];
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
    # Towns for Spotlight's location search, from GeoNames (CC BY 4.0); see update-cities.py.
    gzip -d $out/share/quiet-shell/data/cities.tsv.gz
    makeWrapper ${quickshell}/bin/qs $out/bin/quiet-shell \
      --add-flags "-p $out/share/quiet-shell" \
      --set QT_WAYLAND_DISABLED_INTERFACES ${lib.concatStringsSep "," textInput} \
      --set QUIET_ZONE_TAB ${tzdata}/share/zoneinfo/zone.tab \
      --set QUIET_COUNTRY_TAB ${tzdata}/share/zoneinfo/iso3166.tab \
      --suffix PATH : ${
        lib.concatStringsSep ":" (
          [
            (lib.makeBinPath runtime)
            "$out/bin"
          ]
          ++ extraPath
        )
      }
    makeWrapper ${python3}/bin/python3 $out/bin/quiet-buds \
      --add-flags "$out/share/quiet-shell/scripts/buds.py" \
      --suffix PATH : ${lib.makeBinPath [ bluez ]}
    makeWrapper ${quickshell}/bin/qs $out/bin/quiet-shell-ipc \
      --add-flags "ipc -p $out/share/quiet-shell call shell"
    runHook postInstall
  '';

  # Tests run the helper scripts with the same tools the shell gives them.
  passthru = {
    inherit runtime;
    # The tray's registry, as its own package: inside the shell's, every shell
    # rebuild would restart it too, which is what it exists to avoid.
    trayWatcher = writers.writePython3Bin "quiet-tray-watcher" {
      libraries = [ python3.pkgs.dbus-next ];
      # dbus-next spells D-Bus types as string annotations ("as"), which flake8 reads as names.
      flakeIgnore = [
        "E501"
        "F821"
        "F722"
      ];
    } (builtins.readFile ./tray-watcher.py);
  };

  meta = {
    description = "Quiet, auto-hiding desktop shell for Hyprland";
    mainProgram = "quiet-shell";
    platforms = lib.platforms.linux;
  };
}
