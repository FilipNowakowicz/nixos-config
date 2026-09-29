{ config, pkgs, ... }:
let
  # PokerStars.uk runs in a Bottles bottle named "PokerStars" (created
  # imperatively with `bottles-cli new`). The updater is the client's
  # entry point: it self-updates, then launches PokerStars.exe.
  pokerstarsuk = pkgs.writeShellScriptBin "pokerstarsuk" ''
    exec ${pkgs.bottles}/bin/bottles-cli run -b PokerStars \
      -e "${config.xdg.dataHome}/bottles/bottles/PokerStars/drive_c/Program Files (x86)/PokerStars.UK/PokerStarsUpdate.exe"
  '';
in
{
  imports = [ ../../profiles/python-development.nix ];

  home.packages = with pkgs; [
    bottles
    input-leap
    modrinth-app
    pokerstarsuk
  ];

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
