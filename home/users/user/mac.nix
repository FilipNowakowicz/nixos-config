{ pkgs, hostRegistry, ... }:
let
  mainFQDN = hostRegistry.main.tailnetFQDN;
in
{
  userSecrets.enable = false;

  home.packages = with pkgs; [
    input-leap
    # Upstream nixpkgs pinned moonlight-qt to ffmpeg_8 internally (commit
    # b42f6f7412e374f0c38b9c93a982a0aa76f9e207), so the local override this
    # comment used to describe is gone; plain `moonlight-qt` builds again.
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
