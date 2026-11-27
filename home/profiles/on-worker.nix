# `on-worker`: run long CPU-heavy jobs from any Git checkout on the on-demand
# gcp-builder VM instead of this laptop; it runs jobs as the unprivileged
# `jobs` user next to its builds (#592). See hosts/gcp-builder/CLAUDE.md.
{
  config,
  lib,
  pkgs,
  hostRegistry,
  ...
}:
let
  builder = hostRegistry.gcp-builder;

  # Job results go to the same private ntfy topic as the other fleet
  # notifications; on-worker copies the URL to the worker on each run.
  notifyUrlFile = lib.optionalString (
    config.sops.secrets ? ntfy-topic-url
  ) config.sops.secrets.ntfy-topic-url.path;

  onWorker = pkgs.writeShellApplication {
    name = "on-worker";
    # Remote scripts are sent verbatim, and client-side expansion in the ssh
    # command strings is intended.
    excludeShellChecks = [
      "SC2016"
      "SC2029"
    ];
    runtimeInputs = with pkgs; [
      coreutils
      git
      gnused
      openssh
      rsync
    ];
    # on-worker runs from any repository, so the shared builder library is
    # included at build time and the registry values it would evaluate are
    # set here. builder_user only drives its SSH readiness probe; jobs log in
    # as `jobs`, not the deploy user, and wait longer for SSH than builds do.
    text =
      builtins.readFile ../../scripts/lib/builder.sh
      + ''
        builder_fqdn=${lib.escapeShellArg builder.tailnetFQDN}
        builder_user="jobs"
        builder_ssh_tries=60
        NOTIFY_URL_FILE=${lib.escapeShellArg notifyUrlFile}
      ''
      + builtins.readFile ../files/scripts/on-worker.sh;
  };
in
{
  home.packages = [ onWorker ];
}
