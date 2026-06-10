{
  inputs,
  pkgs,
  ...
}:
{
  imports = [
    inputs.disko.nixosModules.disko
    ./hardware-configuration.nix
    ./disko.nix
    ../../modules/nixos/profiles/base.nix
    ../../modules/nixos/profiles/machine-common.nix
    ../../modules/nixos/profiles/security.nix
    ../../modules/nixos/profiles/sops-base.nix
    ../../modules/nixos/profiles/user.nix
  ];

  system = {
    stateVersion = "24.11";
  };

  # Unlike gcp-builder (broad NOPASSWD for deploy-rs activation), this host runs
  # Claude Code sessions, not deploys — it does not need activation sudo. Keep
  # the narrow `main`-style posture: `wheelNeedsPassword` stays at its default
  # (true), so a compromised session cannot trivially escalate to root. Heavy
  # builds/tests offload to gcp-builder, which is where build-time root lives.
  # SSH is still Tailscale-scoped and key-only.

  networking = {
    hostName = "gcp-agent";
    firewall = {
      checkReversePath = "loose";
      interfaces.tailscale0.allowedTCPPorts = [ 22 ];
    };
  };

  boot = {
    # No ZFS here; pin the 26.11 default explicitly to avoid the eval warning.
    zfs.forceImportRoot = false;
    loader.timeout = 1;
    kernelParams = [
      "console=tty1"
      "console=ttyS0,115200n8"
      "systemd.journald.forward_to_console=1"
    ];
  };

  profiles = {
    # base.nix unconditionally uses lib.profiles.observability.mkPromScript,
    # which only exists when the observability profile is enabled. Turn it on
    # but leave every collector and backend off: this box ships no telemetry and
    # runs no LGTM services — this just satisfies shared base (same as builder).
    observability.enable = true;
  };

  nix = {
    settings.trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "main.local:fSo1pk+WU1RU7vpv+GTbzldKn4MMtBS46vQasXJ2oeQ="
    ];
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
  };

  environment.systemPackages = [
    # Keep common client terminal definitions available over SSH without pulling
    # every terminfo package into the server closure. The agent toolchain
    # (claude, gh, codex, node) is provided through the Home Manager `agent`
    # role (home/users/user/agent.nix).
    pkgs.alacritty.terminfo
    pkgs.foot.terminfo
    pkgs.kitty.terminfo
    pkgs.wezterm.terminfo
  ];

  services = {
    openssh = {
      enable = true;
      openFirewall = false;
    };

    # Auto-join the tailnet on boot. SSH is tailnet-only, so the box MUST get
    # onto the tailnet without a login — same bootstrap as gcp-builder. The auth
    # key is placed at provisioning time via `nixos-anywhere --extra-files` (see
    # CLAUDE.md), not sops: a revocable, tag-scoped key kept only on this box's
    # own disk. Mint it reusable, NON-ephemeral (the box is usually powered off;
    # an ephemeral node would be deregistered while down and lose its stable
    # name), pre-tagged tag:agent. After first join the node identity persists on
    # disk, so the key is used once and then shredded by the cleanup service.
    tailscale = {
      enable = true;
      openFirewall = true;
      authKeyFile = "/var/lib/tailscale-authkey";
      extraUpFlags = [ "--advertise-tags=tag:agent" ];
    };

    journald.extraConfig = ''
      ForwardToConsole=yes
      MaxLevelConsole=info
    '';
  };

  systemd.services.tailscale-authkey-cleanup =
    let
      authKeyPath = "/var/lib/tailscale-authkey";
      script = pkgs.writeShellScript "tailscale-authkey-cleanup" ''
        set -eu

        auth_key=${authKeyPath}

        for _ in $(${pkgs.coreutils}/bin/seq 1 60); do
          if ${pkgs.tailscale}/bin/tailscale status --json --peers=false 2>/dev/null \
            | ${pkgs.jq}/bin/jq -e '(.Self.ID? // "") != ""' >/dev/null; then
            ${pkgs.coreutils}/bin/shred --remove "$auth_key"
            exit 0
          fi

          ${pkgs.coreutils}/bin/sleep 1
        done

        echo "tailscale-authkey-cleanup: tailscale node identity was not established" >&2
        exit 1
      '';
    in
    {
      description = "Remove the gcp-agent Tailscale auth key after first join";
      wantedBy = [ "multi-user.target" ];
      wants = [ "tailscaled-autoconnect.service" ];
      after = [
        "tailscaled.service"
        "tailscaled-autoconnect.service"
      ];
      unitConfig.ConditionPathExists = authKeyPath;
      startLimitIntervalSec = 0;
      startLimitBurst = 1000000;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = script;
        Restart = "on-failure";
        RestartSec = "30s";
      };
    };

  # Host-scoped secrets. This host deliberately does NOT carry the personal
  # `&user` age key (that would give a disposable, autonomously-running box
  # blast-radius over every `&user` secret on every host). Instead its own
  # `claude` login and a repo-scoped GitHub PAT are encrypted to the gcp-agent
  # host key and decrypted at activation by the host SSH key. Both files are
  # placed into `user`'s home where the `claude` CLI and `gh` expect them.
  #
  # The encrypted values are placeholders until captured during provisioning
  # (see hosts/gcp-agent/CLAUDE.md): a fresh `claude` login on this host and a
  # fine-grained PAT (contents + pull-requests + issues, write).
  sops.secrets = {
    # Stored as a binary .enc (not .json): the secrets-directory hook only
    # permits .enc/.age/SOPS-.yaml under hosts/*/secrets/. Binary preserves the
    # JSON bytes verbatim, which is what the `claude` CLI reads.
    claude_credentials = {
      format = "binary";
      sopsFile = ./secrets/claude-credentials.enc;
      path = "/home/user/.claude/.credentials.json";
      owner = "user";
      mode = "0600";
    };

    gh_hosts = {
      format = "yaml";
      key = "";
      sopsFile = ./secrets/gh-hosts.yaml;
      path = "/home/user/.config/gh/hosts.yml";
      owner = "user";
      mode = "0600";
    };
  };

  # Key-only login (personal keys authorized via sops-base). No console password
  # is provisioned; recover a wedged agent box by reprovisioning rather than
  # console, same disposability model as gcp-builder.
  users.users.user.home = "/home/user";
}
