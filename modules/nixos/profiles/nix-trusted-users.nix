{ config, lib, ... }:
let
  trustedUsers = lib.unique ([ "root" ] ++ config.profiles.nix.extraTrustedUsers);
  actualTrustedUsers = lib.unique (config.nix.settings.trusted-users or [ ]);
  missingTrustedUsers = lib.filter (user: !(builtins.elem user actualTrustedUsers)) trustedUsers;
  unexpectedTrustedUsers = lib.filter (user: !(builtins.elem user trustedUsers)) actualTrustedUsers;
  trustedUserViolations = lib.filter (msg: msg != "") [
    (lib.optionalString (
      missingTrustedUsers != [ ]
    ) "missing trusted users: ${lib.concatStringsSep ", " missingTrustedUsers}")
    (lib.optionalString (
      unexpectedTrustedUsers != [ ]
    ) "unexpected trusted users: ${lib.concatStringsSep ", " unexpectedTrustedUsers}")
  ];
  broadTrustedUsers = lib.filter (user: user == "*" || lib.hasPrefix "@" user) trustedUsers;
in
{
  options.profiles.nix.extraTrustedUsers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Additional users to trust in the Nix daemon beyond the fleet baseline.";
  };

  config = {
    nix.settings.trusted-users = trustedUsers;

    assertions = [
      {
        assertion = trustedUserViolations == [ ];
        message = "nix.settings.trusted-users must stay scoped to profiles.nix.extraTrustedUsers: ${lib.concatStringsSep "; " trustedUserViolations}";
      }
      {
        # Broad trust (`*` or any `@group`) is root-equivalent: a trusted Nix
        # user can substitute arbitrary store paths and override sandbox/build
        # settings. Fail the build instead of merely warning so CI rejects it.
        assertion = broadTrustedUsers == [ ];
        message = "nix.settings.trusted-users must not contain broad entries (${lib.concatStringsSep ", " broadTrustedUsers}); broad trust is root-equivalent. List exact users in profiles.nix.extraTrustedUsers instead.";
      }
    ];
  };
}
