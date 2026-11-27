# Narrow passwordless maintenance for agent-assisted sessions: the sudo
# allowlist and the fixed-argument wrappers it exempts. Keep wheel passworded
# globally; only these exact commands are exempt.
{
  config,
  pkgs,
  hostRegistry,
  ...
}:
let
  user = config.profiles.primaryUser;
  inherit (config.users.users.${user}) home;

  agentMaintenanceCommands = [
    # Verify and trigger post-reinstall backup/check jobs.
    "/run/current-system/sw/bin/systemctl start restic-backups-local.service"
    "/run/current-system/sw/bin/systemctl start restic-check-local.service"
    "/run/current-system/sw/bin/systemctl status restic-backups-local.service --no-pager"
    "/run/current-system/sw/bin/systemctl status restic-backups-local.timer --no-pager"
    "/run/current-system/sw/bin/systemctl status restic-check-local.service --no-pager"
    "/run/current-system/sw/bin/systemctl status restic-check-local.timer --no-pager"
    "/run/current-system/sw/bin/systemctl start btrbk-local.service"
    "/run/current-system/sw/bin/systemctl status btrbk-local.service --no-pager"
    "/run/current-system/sw/bin/systemctl status btrbk-local.timer --no-pager"

    # Clean stale boot entries and old system generations after rebuilds.
    "/run/current-system/sw/bin/bootctl status --no-pager"
    "/run/current-system/sw/bin/bootctl cleanup"
    "/run/current-system/sw/bin/efibootmgr -b [0-9A-F][0-9A-F][0-9A-F][0-9A-F] -B"
    "/run/current-system/sw/bin/nix-gc-14d"

    # Root-equivalent activation path for agent-assisted local rebuilds.
    # Keep this scoped to the fixed-argument wrapper below rather than granting
    # broad passwordless sudo or arbitrary nh/nixos-rebuild commands.
    "/run/current-system/sw/bin/nixos-switch-main"
  ];

  passwordlessAgentCommand = command: {
    inherit command;
    options = [ "NOPASSWD" ];
  };

  # nh >= 4.3 added a hard "don't run nh as root" guard, which broke this
  # NOPASSWD wrapper: it is invoked as root via `sudo nixos-switch-main`, and nh
  # then refuses. Build and activate the closure directly instead — the same
  # manual pattern used for homeserver-gcp (nix build toplevel +
  # switch-to-configuration), so the passwordless agent-rebuild path keeps
  # working without granting broad NOPASSWD or running nh as root.
  nixosSwitchMain = pkgs.writeShellScriptBin "nixos-switch-main" ''
    set -euo pipefail
    flake=${home}/nix
    # Root building a user-owned checkout otherwise trips git's dubious-ownership
    # guard; scope the exception to this flake path only.
    export HOME=/root
    ${pkgs.git}/bin/git config --global --add safe.directory "$flake" || true
    # --remote does the builds on gcp-builder. The caller starts the VM first
    # (`bash scripts/on-builder.sh true`). It takes no other argument, so this
    # passwordless command still can only activate this checkout.
    remote_args=()
    if [ "''${1:-}" = --remote ]; then
      remote_args=(
        --max-jobs 0
        --builders "ssh-ng://${hostRegistry.gcp-builder.deploy.sshUser}@${hostRegistry.gcp-builder.tailnetFQDN} x86_64-linux /run/secrets/gcp_builder_build_key 8 2 kvm,nixos-test,big-parallel,benchmark"
      )
    fi
    toplevel=$(${pkgs.nix}/bin/nix build --no-link --print-out-paths "''${remote_args[@]}" \
      "$flake#nixosConfigurations.main.config.system.build.toplevel")
    ${pkgs.nix}/bin/nix-env -p /nix/var/nix/profiles/system --set "$toplevel"
    exec "$toplevel/bin/switch-to-configuration" switch
  '';

  nixGc14d = pkgs.writeShellScriptBin "nix-gc-14d" ''
    exec ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 14d
  '';
in
{
  environment.systemPackages = [
    nixGc14d
    nixosSwitchMain
  ];

  security.sudo = {
    extraConfig = ''
      Defaults lecture=never
    '';
    extraRules = [
      {
        users = [ user ];
        commands = map passwordlessAgentCommand agentMaintenanceCommands;
      }
    ];
  };
}
