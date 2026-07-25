{ lib, hostMeta, ... }:
let
  backup = hostMeta.backup or { };
  backupClass = backup.class or null;
  backupName = backup.name or "local";

  # Canonical definition (and the rationale for --group-by host) lives in
  # lib/backup-policy.nix; flake/checks.nix's homeserver-gcp invariant reads
  # the same file so the two can't drift out of sync.
  pruneOptsByClass = import ../../../lib/backup-policy.nix;
in
lib.mkIf (backupClass != null) {
  services.restic.backups.${backupName} = {
    initialize = true;
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
    pruneOpts = pruneOptsByClass.${backupClass};
  };
}
