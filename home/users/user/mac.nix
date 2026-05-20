{ pkgs, ... }:
{
  userSecrets.enable = false;

  home.packages = with pkgs; [
    input-leap
    moonlight-qt
  ];

  services.syncthing = {
    enable = true;
    tray.enable = true;
  };

  programs.zsh.shellAliases = {
    input-main = "input-leapc main.tail90fc7a.ts.net";
    moon-main = "moonlight stream main.tail90fc7a.ts.net";
  };
}
