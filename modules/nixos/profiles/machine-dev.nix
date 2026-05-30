{ config, lib, ... }:
{
  options.profiles.machineDev.enable = lib.mkEnableOption ''
    disposable/dev-only host posture: broad passwordless sudo, open SSH
    firewall, and a trusted Nix user. Treat SSH access to such a host as
    root-equivalent. Do not enable on multi-user or untrusted-shell hosts.
  '';

  config = lib.mkIf config.profiles.machineDev.enable {
    security.sudo.wheelNeedsPassword = false;
    services.openssh.openFirewall = true;
    profiles.nix.extraTrustedUsers = [ "user" ];
  };
}
