# The baseline both GCE hosts (homeserver-gcp, gcp-builder) share: a headless
# VM reachable only over Tailscale SSH, with a serial console for recovery and
# deploy-rs activation. Hosts add their own services, disko layout, Tailscale
# auth key and flags, and authorized keys.
{
  config,
  lib,
  pkgs,
  hostMeta,
  ...
}:
let
  user = config.profiles.primaryUser;
  exitNode = hostMeta.tailscale.exitNodeCanProvide or false;
  binaryCache = import ../../../lib/binary-cache.nix;
in
{
  imports = [
    ../hardware/gce-vm.nix
    ./base.nix
    ./fleet-cache.nix
    ./security.nix
    ./sops-base.nix
    ./user.nix
  ];

  # Broad passwordless sudo: deploy-rs needs it for activation. SSH access to
  # these hosts is therefore root-equivalent; keep SSH Tailscale-scoped and
  # key-only (docs/security.md).
  security.sudo.wheelNeedsPassword = false;

  # deploy-rs and remote builds connect as the primary user; trust it so the daemon
  # accepts remote-build store operations and restricted settings.
  profiles.nix.extraTrustedUsers = [ user ];

  nix.settings.trusted-public-keys = [
    binaryCache.cacheNixosOrgPublicKey
    binaryCache.mainLocalPublicKey
  ];

  # The GCE serial console is the recovery path when the tailnet is down, so
  # send the console and the journal there too.
  boot = {
    loader.timeout = 1;
    kernelParams = [
      "console=tty1"
      "console=ttyS0,115200n8"
      "systemd.journald.forward_to_console=1"
    ];
  };

  networking.firewall.checkReversePath = "loose";

  services = {
    # The firewall stays closed; hosts open port 22 on tailscale0 only.
    openssh = {
      enable = true;
      openFirewall = lib.mkDefault false;
    };

    tailscale = {
      enable = true;
      openFirewall = true;
      # `--reset` makes the boot-time `tailscale up` normalize every pref to the
      # declared set instead of reconciling against persisted on-disk prefs.
      # Without it, any drift in /var/lib/tailscale (e.g. a stale RouteAll /
      # Hostname pref) makes `tailscale up` abort with "changing settings
      # requires mentioning all non-default flags", so tailscaled-autoconnect
      # fails, the node never joins, and tailnet-only SSH is unreachable — the
      # homeserver's 2026-06-21 outage. Flags a host adds must be mentioned
      # explicitly, since --reset drops everything else.
      extraUpFlags = [ "--reset" ];
    }
    // lib.optionalAttrs exitNode {
      # Registry `tailscale.exitNodeCanProvide`: offer this host as an exit
      # node. `tailscale set` runs on every tailscaled start, after the
      # autoconnect `up --reset`, so the advertisement survives a re-login.
      # The ACL auto-approves it; devices still opt in from their client.
      # Exit traffic leaves NATed to this VM, so GCE IP forwarding stays off.
      useRoutingFeatures = "server";
      extraSetFlags = [ "--advertise-exit-node" ];
    };

    journald.settings.Journal = {
      ForwardToConsole = true;
      MaxLevelConsole = "info";
    };
  };

  # nixpkgs wants tailscaled-set only from tailscaled.service, so the switch
  # that first adds it might not run it until tailscaled restarts. Wanting it
  # from multi-user.target too makes that switch apply the advertisement.
  systemd.services.tailscaled-set = lib.mkIf exitNode { wantedBy = [ "multi-user.target" ]; };

  users.users.${user}.home = "/home/${user}";

  environment.systemPackages = [
    # Keep common client terminal definitions available over SSH without pulling
    # every terminfo package into the server closure.
    pkgs.alacritty.terminfo
    pkgs.foot.terminfo
    pkgs.kitty.terminfo
    pkgs.wezterm.terminfo
  ];
}
