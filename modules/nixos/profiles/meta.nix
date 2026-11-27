{ lib, ... }:
{
  options.profiles = {
    ci = lib.mkEnableOption "CI evaluation mode — disables hardware-dependent features";

    primaryUser = lib.mkOption {
      type = lib.types.str;
      default = "user";
      description = ''
        Login name of the fleet's single interactive and deploy account. Host
        and shared NixOS modules read this rather than spelling the name out.
        Home Manager modules under home/users/user still assume `user`.
      '';
    };
  };
}
