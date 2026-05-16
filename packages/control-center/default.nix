{
  lib,
  stdenv,
  bash,
  python3,
  gobject-introspection,
  wrapGAppsHook4,
  glib,
  pango,
  gdk-pixbuf,
  graphene,
  harfbuzz,
  gtk4,
  gtk4-layer-shell,
  bluez,
  brightnessctl,
  curl,
  mako,
  networkmanager,
  networkmanagerapplet,
  mullvad-vpn,
  power-profiles-daemon,
  systemd,
  tailscale,
  wireplumber,
  wlsunset,
}:

let
  python = python3.withPackages (ps: [ ps.pygobject3 ]);

  runtimePath = lib.makeBinPath [
    bluez
    brightnessctl
    curl
    mako
    networkmanager
    networkmanagerapplet
    mullvad-vpn
    power-profiles-daemon
    systemd
    tailscale
    wireplumber
    wlsunset
  ];
in
stdenv.mkDerivation {
  pname = "control-center";
  version = "0";

  src = ./src;

  nativeBuildInputs = [
    gobject-introspection
    wrapGAppsHook4
  ];

  buildInputs = [
    glib
    pango
    gdk-pixbuf
    graphene
    harfbuzz
    gtk4
    gtk4-layer-shell
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/libexec
    cp -r $src $out/libexec/python

    cat > $out/bin/control-center <<EOF
    #!${bash}/bin/sh
    exec ${python}/bin/python3 -m control_center "\$@"
    EOF
    chmod +x $out/bin/control-center

    runHook postInstall
  '';

  preFixup = ''
    gappsWrapperArgs+=(
      --set GDK_BACKEND wayland
      --set GTK4_LAYER_SHELL_LIB "${gtk4-layer-shell}/lib/libgtk4-layer-shell.so.0"
      --prefix PATH : "${runtimePath}"
      --prefix PYTHONPATH : "$out/libexec/python"
    )
  '';

  meta = with lib; {
    description = "Unified system control panel (Wayland, GTK4 layer shell)";
    platforms = platforms.linux;
    mainProgram = "control-center";
  };
}
