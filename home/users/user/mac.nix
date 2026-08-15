{ pkgs, hostRegistry, ... }:
let
  mainFQDN = hostRegistry.main.tailnetFQDN;
in
{
  userSecrets.enable = false;

  home.packages = with pkgs; [
    input-leap
    # nixpkgs' default `ffmpeg` moved to 9.0, which dropped AVCodec.pix_fmts;
    # moonlight-qt hasn't caught up yet (upstream nixpkgs fixed this the same
    # way in commit b42f6f7412e374f0c38b9c93a982a0aa76f9e207 by pinning to
    # ffmpeg_8, just after our current nixpkgs pin). Drop this override once
    # that lands in nixos-unstable and plain `moonlight-qt` builds again.
    (moonlight-qt.override { ffmpeg = ffmpeg_8; })
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
