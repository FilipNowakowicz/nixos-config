# Invariants that guard hosts/gcp-builder alone, beside the config they read.
# flake/checks.nix layers `invariants` on the fleet baseline for
# `invariants-gcp-builder`.
{
  lib,
  invariants,
  hostRegistry,
  ...
}:
let
  inherit (invariants) formatList interfaceTCPExposureViolations mkResult;

  builderMeta = hostRegistry.gcp-builder;

  # CI runners (tag:ci-builder) have no tailnet DNS and no Nix, so the
  # workflows pin the builder's address and login as env values. Every
  # workflow that reaches the builder must set both, to the registry's values.
  ciWorkflowsMatchRegistry = {
    name = "CI workflows address gcp-builder by its registry IP and login";
    check =
      _:
      let
        expected = {
          BUILDER_FQDN = builderMeta.tailscale.ip4;
          BUILDER_USER = builderMeta.deploy.sshUser;
        };
        workflows = [
          "nix.yml"
          "deploy-homeserver.yml"
        ];
        envValues =
          file: key:
          lib.concatMap (
            line:
            let
              m = builtins.match "[[:space:]]*${key}:[[:space:]]*([^[:space:]#]+).*" line;
            in
            lib.optional (m != null) (builtins.head m)
          ) (lib.splitString "\n" (builtins.readFile (../../.github/workflows + "/${file}")));
        violations = lib.concatMap (
          file:
          lib.concatMap (
            key:
            let
              values = envValues file key;
            in
            if values == [ ] then
              [ "${file} sets no ${key}" ]
            else
              map (v: "${file}: ${key} is ${v}, registry says ${expected.${key}}") (
                lib.filter (v: v != expected.${key}) values
              )
          ) (builtins.attrNames expected)
        ) workflows;
      in
      mkResult (violations == [ ]) (lib.concatStringsSep "; " violations);
  };

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
    ciWorkflowsMatchRegistry
  ];
}
