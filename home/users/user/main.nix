{ config, pkgs, ... }:
let
  # PokerStars.uk runs in a Bottles bottle named "PokerStars" (created
  # imperatively with `bottles-cli new`). The updater is the client's
  # entry point: it self-updates, then launches PokerStars.exe.
  pokerstarsuk = pkgs.writeShellScriptBin "pokerstarsuk" ''
    exec ${pkgs.bottles}/bin/bottles-cli run -b PokerStars \
      -e "${config.xdg.dataHome}/bottles/bottles/PokerStars/drive_c/Program Files (x86)/PokerStars.UK/PokerStarsUpdate.exe"
  '';

  # Runner for the PokerStars bottle (its bottle.yml sets `Runner:` to this
  # directory name; the bottle also forces Wine's X11 driver via
  # HKCU\Software\Wine\Drivers Graphics=x11, because the Wayland driver's EGL
  # path falls back to CPU rendering for the Cocos tables). Wine 11.18 makes
  # the client's hot EnumWindows/GetWindowLong loop ~2x cheaper than soda 11.0
  # and uses /dev/ntsync (loaded in hosts/main) for waits.
  pokerstarsRunner = pkgs.fetchzip {
    url = "https://github.com/Kron4ek/Wine-Builds/releases/download/11.18/wine-11.18-staging-tkg-amd64-wow64.tar.xz";
    hash = "sha256-1goBPx5GSfx58ViU0euuQUVVSb3zZcvJmx+0db7QiHY=";
  };
in
{
  imports = [ ../../profiles/python-development.nix ];

  home.packages = with pkgs; [
    bottles
    input-leap
    modrinth-app
    pokerstarsuk
  ];

  xdg.dataFile."bottles/runners/wine-11.18-staging-tkg-amd64-wow64".source = pokerstarsRunner;

  xdg.desktopEntries.pokerstarsuk = {
    name = "PokerStars.uk";
    exec = "pokerstarsuk";
    icon = "applications-games";
    categories = [ "Game" ];
  };

  programs.zsh.shellAliases = {
    input-server = "input-leaps --address $(tailscale ip -4)";
  };
}
