{ config, pkgs, ... }:
{
  users.users.${config.profiles.primaryUser} = {
    isNormalUser = true;
    description = "Primary user";
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    shell = pkgs.zsh;
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "backup";
  };
}
