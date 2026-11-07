{ ... }:
{
  imports = [
    ./profiles/backup.nix
    ./profiles/meta.nix
    ./profiles/nix-trusted-users.nix
    ./profiles/runtime-timezone.nix
    ./profiles/observability
    ./services/systemd-failure-notify.nix
    ./services/hardened.nix
  ];
}
