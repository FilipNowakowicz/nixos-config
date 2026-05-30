{ modulesPath, ... }:
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  system.stateVersion = "24.11";

  boot.zfs.forceImportRoot = false;

  networking.firewall.allowedTCPPorts = [ 22 ];

  services.openssh = {
    enable = true;
    settings = {
      # SSH on the installer is firewall-open on TCP/22; allow only key-based
      # root login (nixos-anywhere needs root) and kill every password path.
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  users.users.root.openssh.authorizedKeys.keys = import ../../lib/pubkeys.nix;
}
