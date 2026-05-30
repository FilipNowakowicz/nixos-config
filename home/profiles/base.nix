{ config, pkgs, ... }:
{
  # ── Packages ────────────────────────────────────────────────────────────────
  home.packages = with pkgs; [
    # Core CLI
    bat
    btop
    eza
    fd
    jq
    less
    ripgrep
    tree
    unzip
    which
    zip

    # Utilities
    nix-output-monitor
    nh
  ];

  # ── Environment Variables ──────────────────────────────────────────────────
  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    MANPAGER = "nvim +Man!";
    PAGER = "less -R";
  };

  programs = {
    home-manager.enable = true;

    # ── Git ────────────────────────────────────────────────────────────────────
    git = {
      enable = true;
      settings = {
        init.defaultBranch = "main";
        pull.ff = "only";
        core.editor = "nvim";
        push.autoSetupRemote = true;
        rebase.autosquash = true;
        rerere.enabled = true;
      };
    };

    # ── Delta (git diff pager) ─────────────────────────────────────────────────
    delta = {
      enable = true;
      enableGitIntegration = true;
      options = {
        navigate = true;
        line-numbers = true;
      };
    };

    # ── Starship Prompt ────────────────────────────────────────────────────────
    starship = {
      enable = true;
      enableZshIntegration = false;
      settings = {
        add_newline = false;
        format = "$hostname$directory$python$nix_shell$character";
        hostname = {
          ssh_only = true;
          format = "\\[[$hostname]($style)\\] ";
          style = "fg:#d79921 bold";
          trim_at = ".";
        };
        directory = {
          truncation_length = 2;
          truncate_to_repo = false;
          format = "$path ";
          style = "";
        };
        nix_shell = {
          format = "[\\($symbol\\)]($style) ";
          symbol = "nix";
          style = "fg:#83a598";
        };
        python = {
          format = "[\\($symbol\\)]($style) ";
          symbol = "venv";
          style = "fg:#DAA520";
        };
        character = {
          success_symbol = "[%]()";
          error_symbol = "[%](red)";
        };
      };
    };

    # ── FZF ────────────────────────────────────────────────────────────────────
    fzf = {
      enable = true;
      enableZshIntegration = true;
    };

    # ── Zoxide ─────────────────────────────────────────────────────────────────
    zoxide = {
      enable = true;
      enableZshIntegration = true;
    };

    # ── Bat ────────────────────────────────────────────────────────────────────
    bat = {
      enable = true;
      config = {
        theme = "base16";
        italic-text = "always";
      };
    };
  };

  # ── SSH Agent ──────────────────────────────────────────────────────────────
  services.ssh-agent.enable = true;

  # ── Zsh ────────────────────────────────────────────────────────────────────
  programs.zsh = {
    enable = true;
    dotDir = "${config.xdg.configHome}/zsh";
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    enableCompletion = true;

    history = {
      size = 10000;
      save = 10000;
      ignoreAllDups = true;
      share = true;
      append = true;
    };

    initContent = ''
      # Options
      setopt autocd correct extendedglob noclobber
      setopt interactivecomments nobeep
      setopt autopushd pushdignoredups
      setopt nohup nocheckjobs

      # Vi mode + edit in $EDITOR
      bindkey -v
      autoload -Uz edit-command-line; zle -N edit-command-line
      bindkey -M vicmd 'v' edit-command-line

      # History-prefix search on arrows
      autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
      zle -N up-line-or-beginning-search
      zle -N down-line-or-beginning-search
      bindkey '^[[A' up-line-or-beginning-search
      bindkey '^[[B' down-line-or-beginning-search

      # Completion styling
      zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'
      zstyle ':completion:*' menu select
      zstyle ':completion:*' use-cache on
      zstyle ':completion:*' cache-path "''${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
      zstyle ':completion:*' rehash true

      # Use the shared systemd-managed SSH agent in every shell.
      export SSH_AUTH_SOCK="''${XDG_RUNTIME_DIR:-/run/user/$UID}/ssh-agent"
      if [[ -S "$SSH_AUTH_SOCK" ]]; then
        ssh-add -l >/dev/null 2>&1
        if [[ $? -eq 1 && -r "$HOME/.ssh/id_ed25519" ]]; then
          ssh-add -q "$HOME/.ssh/id_ed25519"
        fi
      fi

      # Accept autosuggestion with Ctrl+Space
      (( ''${+widgets[autosuggest-accept]} )) && bindkey '^ ' autosuggest-accept

      command_not_found_handle() {
        emulate -L zsh

        local cmd="$1"
        local attrs
        attrs=("''${(@f)$(/run/current-system/sw/bin/nix-locate --minimal --no-group --type x --type s --whole-name --at-root "/bin/$cmd" 2>/dev/null)}")

        if (( $#attrs == 0 )); then
          print -u2 -- "$cmd: command not found"
          return 127
        fi

        if (( $#attrs == 1 )); then
          print -u2 -- "The program '$cmd' is currently not installed."
          print -u2 -- "Run it once with:"
          print -u2 -- "  , $cmd ..."
          print -u2 -- ""
          print -u2 -- "Or with an explicit flake package:"
          print -u2 -- "  nix shell nixpkgs#''${attrs[1]} -c $cmd ..."
          print -u2 -- ""
          print -u2 -- "To install it permanently:"
          print -u2 -- "  nix profile install nixpkgs#''${attrs[1]}"
          return 127
        fi

        print -u2 -- "The program '$cmd' is currently not installed."
        print -u2 -- "Run it once with:"
        print -u2 -- "  , $cmd ..."
        print -u2 -- ""
        print -u2 -- "Or choose a specific package:"
        local attr
        for attr in $attrs; do
          print -u2 -- "  nix shell nixpkgs#$attr -c $cmd ..."
        done
        print -u2 -- ""
        print -u2 -- "To install one permanently:"
        for attr in $attrs; do
          print -u2 -- "  nix profile install nixpkgs#$attr"
        done
        return 127
      }

      command_not_found_handler() {
        command_not_found_handle "$@"
      }

      # Starship init
      eval "$(starship init zsh)"
    '';
  };

  # ── XDG User Dirs ──────────────────────────────────────────────────────────
  xdg.userDirs = {
    enable = true;
    createDirectories = true;
    download = "${config.home.homeDirectory}/Downloads";
    desktop = null;
    documents = null;
    music = null;
    pictures = null;
    projects = null;
    publicShare = null;
    templates = null;
    videos = null;
  };
}
