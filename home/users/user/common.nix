{
  config,
  lib,
  ...
}:
{
  imports = [
    ../../profiles/fleet.nix
    ../../profiles/base.nix
    ../../neovim/module.nix
  ];

  home = {
    username = "user";
    homeDirectory = "/home/user";
    stateVersion = "24.11";

    sessionPath = [
      "${config.home.homeDirectory}/.local/bin"
      "${config.home.homeDirectory}/.npm-global/bin"
    ];
  };

  # user.name and user.email are rendered at activation by secrets.nix via a
  # sops template + programs.git.includes. Hosts with userSecrets.enable = false
  # (mac, wsl) must set identity manually (`git config --global user.{name,email}`).
  programs.git = {
    enable = true;
    signing = {
      format = "ssh";
      key = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";
      signByDefault = true;
    };
  };

  programs.zsh = {
    shellAliases = {
      # Files
      ll = "ls -lh --color=auto";
      la = "ls -A";
      l = "ls -CF";
      cp = "cp -i";
      mv = "mv -i";
      # Navigation
      ".." = "cd ..";
      "..." = "cd ../..";
      "...." = "cd ../../..";
      d = "dirs -v";
      # Git
      g = "git";
      ga = "git add";
      gd = "git diff";
      gco = "git checkout";
      gb = "git branch";
      gc = "git commit -m";
      gca = "git commit -am";
      gp = "git push";
      gl = "git pull";
      glog = "git log --oneline --graph --decorate";
      gs = "git status";
      # Nix
      ns = "nix-shell --run zsh";
      nb = "nix build";
      nd = "nix develop";
      nf = "nix flake";
    };

    initContent = ''
      mkcd()   { mkdir -p -- "$1" && cd -- "$1"; }
      detach() { setsid -f "$@" >/dev/null 2>&1 < /dev/null; }
      extract() {
        [[ -f "$1" ]] || { echo "extract: file not found: $1" >&2; return 1; }
        case "$1" in
          *.tar.bz2) tar xjf "$1" ;;
          *.tar.gz)  tar xzf "$1" ;;
          *.tar.xz)  tar xJf "$1" ;;
          *.tar.zst) tar --zstd -xf "$1" ;;
          *.zip)     unzip "$1" ;;
          *.7z)      7z x "$1" ;;
          *) echo "extract: unsupported format: $1" >&2; return 2 ;;
        esac
      }

      bindkey "''${terminfo[kcuu1]}" history-beginning-search-backward
      bindkey "''${terminfo[kcud1]}" history-beginning-search-forward
    '';
  };

  my.neovim.enable = lib.mkDefault true;

  xdg.userDirs.setSessionVariables = false;
}
