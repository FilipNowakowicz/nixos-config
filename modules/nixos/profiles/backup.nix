{ lib, hostMeta, ... }:
let
  backup = hostMeta.backup or { };
  backupClass = backup.class or null;
  backupName = backup.name or "local";

  # forget's default --group-by is "host,paths": snapshots are only compared
  # against the keep-* policy within snapshots that share the *exact* same
  # backup path list. Every time a host's backed-up paths change (renaming a
  # staging dir, adding/removing a path), forget starts a fresh group that
  # can't yet exceed the policy on its own, so the older group's snapshots
  # never age out even though they're well past the keep-daily/weekly/
  # monthly/yearly window. Grouping by host only is what a single-host
  # backup target actually wants: one retention pool across all of that
  # host's snapshots, regardless of how the path list evolved. Discovered
  # on homeserver-gcp: 3 path-list changes over ~2.5 months left 22 stale
  # snapshots unpruned that the default grouping silently never touched.
  pruneOptsByClass = {
    critical = [
      "--group-by host"
      "--keep-daily 14"
      "--keep-weekly 8"
      "--keep-monthly 6"
      "--keep-yearly 2"
    ];
    standard = [
      "--group-by host"
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 3"
    ];
  };
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
