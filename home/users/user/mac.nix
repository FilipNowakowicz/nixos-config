{ pkgs, hostRegistry, ... }:
let
  mainFQDN = hostRegistry.main.tailnetFQDN;
in
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
    input-main = "input-leapc ${mainFQDN}";
    moon-main = "moonlight stream ${mainFQDN}";
  };
}
