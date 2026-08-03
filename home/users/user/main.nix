{ pkgs, ... }:
{
  imports = [ ../../profiles/python-development.nix ];

  home.packages = with pkgs; [
    input-leap
  ];

  programs.zsh.shellAliases = {
    input-server = "input-leaps --address $(tailscale ip -4)";
  };
}
