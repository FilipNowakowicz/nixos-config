# Runs Lenovo's Windows driver for Synaptics Tudor fingerprint sensors on Linux, sandboxed.
# libfprint has no driver of its own for these, such as the 06cb:00be in the Yoga 9.
{
  lib,
  stdenv,
  fetchurl,
  fetchFromGitHub,
  pkg-config,
  meson,
  ninja,
  innoextract,
  openssl,
  libusb1,
  libcap,
  libseccomp,
  glib,
  dbus,
  libfprint-tod,
  gusb,
  gccForLibs,
}:
let
  installer = fetchurl {
    url = "https://download.lenovo.com/pccbbs/mobiles/r19fp02w.exe";
    hash = "sha256-CfBurJRksBhsGxyN7Xlppik3Lh14nPxsi9d3xydbaY8=";
  };
in
stdenv.mkDerivation {
  pname = "libfprint-2-tod1-synatudor";
  version = "0-unstable-2025-06-17";

  src = fetchFromGitHub {
    owner = "Popax21";
    repo = "synaTudor";
    rev = "31dfdb06107fd1c35c9f9ceae72617e98eccc43a";
    hash = "sha256-/Uh9O2NahVcFg+lk5DkodECOTIyZZwcPs7OKOepagoQ=";
  };

  preConfigure = ''
    substituteInPlace meson.build \
      --replace-fail '/sbin' '${placeholder "out"}/bin'
    substituteInPlace tudor-host/src/sandbox.c \
      --replace-fail '/sbin/tudor' '${placeholder "out"}/bin/tudor'

    # Waking from sleep resumes a nanosleep through restart_syscall, and the sandbox
    # killed the host for it. Upstream PR 72.
    substituteInPlace tudor-host/src/sandbox.c --replace-fail \
      'SCMP_SYS(clock_nanosleep), 0));' \
      'SCMP_SYS(clock_nanosleep), 0)); cant_fail(seccomp_rule_add(scmp_ctx, SCMP_ACT_ALLOW, SCMP_SYS(restart_syscall), 0));'
    # First pairing on 06cb:00be needs one page more than this. Upstream issue 63.
    substituteInPlace tudor-host/src/sandbox.h \
      --replace-fail '(128 * 1024 * 1024)' '(256 * 1024 * 1024)'

    substituteInPlace libtudor/download_driver.sh \
      --replace-fail 'wget https://download.lenovo.com/pccbbs/mobiles/r19fp02w.exe -O "$INSTALLER"' \
      'cp ${installer} "$INSTALLER"'
    # fetchurl has checked the hash, so this doesn't need perl.
    sed -i '/shasum "$INSTALLER"/d' libtudor/download_driver.sh

    rm -r cli/
    sed -i '/cli/d' meson.build
  '';

  enableParallelBuilding = false;
  dontUseCmakeConfigure = true;

  nativeBuildInputs = [
    pkg-config
    meson
    ninja
    innoextract
  ];

  buildInputs = [
    openssl
    libusb1
    libcap
    libseccomp
    glib
    dbus
    libfprint-tod
    gusb
    gccForLibs.libgcc
  ];

  env.NIX_CFLAGS_COMPILE = "-I${glib.dev}/include/gio-unix-2.0 -I${libfprint-tod}/include/libfprint-2";

  installPhase = ''
    runHook preInstall

    install -D tudor-host-launcher/tudor_host_launcher -t $out/bin/tudor
    install -D tudor-host/tudor_host -t $out/bin/tudor
    install -D libtudor/libtudor.so -t $out/lib
    install -D libfprint-tod/libtudor_tod.so -t $out/lib/libfprint-2/tod-1

    mkdir -p $out/lib/systemd/system
    substitute $src/tudor-host-launcher/tudor-host-launcher.service \
      $out/lib/systemd/system/tudor-host-launcher.service \
      --replace-fail '/sbin/tudor' "$out/bin/tudor"
    install -D $src/libfprint-tod/60-tudor-libfprint-tod.rules -t $out/lib/udev/rules.d
    install -D tudor-host-launcher/net.reactivated.TudorHostLauncher.service -t $out/share/dbus-1/system-services
    install -D $src/tudor-host-launcher/net.reactivated.TudorHostLauncher.conf -t $out/share/dbus-1/system.d

    runHook postInstall
  '';

  passthru.driverPath = "/lib/libfprint-2/tod-1";

  meta = {
    description = "Synaptics Tudor fingerprint driver, relinked from Lenovo's Windows driver";
    homepage = "https://github.com/Popax21/synaTudor";
    license = lib.licenses.unfreeRedistributable;
    platforms = [ "x86_64-linux" ];
  };
}
