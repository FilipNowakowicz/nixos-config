# `args.osConfig` rather than an `osConfig` parameter: the module system
# forwards every named argument, so a standalone Home Manager evaluation (the
# public `homeModules.*`) would throw on it even with a `? null` default.
{ lib, ... }@args:
{
  options.fleet = {
    skipHeavyPackages = lib.mkOption {
      type = lib.types.bool;
      default = args.osConfig.profiles.ci or false;
      defaultText = lib.literalExpression "osConfig.profiles.ci or false";
      description = ''
        Skip heavyweight interactive packages for CI and lean profiles.
        Follows the NixOS `profiles.ci` option when Home Manager runs as a
        NixOS module.
      '';
    };
  };
}
