# Invariants that guard hosts/gcp-builder alone, beside the config they read.
# flake/checks.nix layers `invariants` on the fleet baseline for
# `invariants-gcp-builder`.
{ lib, invariants, ... }:
let
  inherit (invariants) formatList interfaceTCPExposureViolations mkResult;

  onDemandSshTailscaleOnly = {
    name = "on-demand GCE host SSH stays Tailscale-only";
    check =
      cfg:
      let
        violations =
          lib.filter (msg: msg != "") [
            (lib.optionalString (!cfg.services.openssh.enable) "services.openssh.enable must be true")
            (lib.optionalString cfg.services.openssh.openFirewall "services.openssh.openFirewall must be false")
          ]
          ++ interfaceTCPExposureViolations {
            interface = "tailscale0";
            ports = [ 22 ];
          } cfg;
      in
      mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
  };

  onDemandUsersAreKeyOnly = {
    name = "on-demand GCE host users stay key-only";
    check =
      cfg:
      let
        passwordFields = [
          "hashedPassword"
          "hashedPasswordFile"
          "initialHashedPassword"
          "initialPassword"
          "passwordFile"
        ];
        hasPassword = user: lib.any (field: (user.${field} or null) != null) passwordFields;
        loginUsers = lib.filterAttrs (
          _: user: user.isNormalUser or false || !(user.isSystemUser or false)
        ) (cfg.users.users or { });
        offenders = lib.attrNames (lib.filterAttrs (_: hasPassword) loginUsers);
      in
      mkResult (
        offenders == [ ]
      ) "password material configured for login user(s): ${formatList offenders}";
  };

  # on-worker hosts run arbitrary project code as `jobs`; keep that account off
  # every root-equivalent path (wheel/sudo, Nix daemon trust).
  workerJobsUserUnprivileged = {
    name = "on-worker jobs user stays unprivileged";
    check =
      cfg:
      let
        jobs = cfg.users.users.jobs or null;
        trusted = cfg.nix.settings.trusted-users or [ ];
        violations = lib.filter (msg: msg != "") (
          if jobs == null then
            [ "users.users.jobs must exist" ]
          else
            [
              (lib.optionalString (builtins.elem "wheel" (jobs.extraGroups or [ ])) "jobs must not be in wheel")
              (lib.optionalString (builtins.elem "jobs" trusted) "jobs must not be a trusted Nix user")
              (lib.optionalString (builtins.elem "@users" trusted) "trusted-users must not include @users")
              (lib.optionalString (
                !(jobs.linger or false)
              ) "jobs must linger so detached jobs outlive their SSH session")
            ]
        );
      in
      mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
  };
in
{
  invariants = invariants.deployTargetBaseAccessAssertions ++ [
    onDemandSshTailscaleOnly
    onDemandUsersAreKeyOnly
    workerJobsUserUnprivileged
  ];
}
