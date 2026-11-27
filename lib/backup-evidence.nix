# Success timestamps that backup jobs leave for node_exporter, one metric per
# kind of evidence. The jobs that write them (modules/nixos/profiles/backup.nix,
# hosts/homeserver-gcp/{backups,restore-drill}.nix) and the alert rules in
# lib/observability-alerts.nix all take the names from here.
let
  metrics = {
    # Every host with a registry `backup` entry: daily snapshot and weekly
    # integrity check, both from profiles/backup.nix.
    backup = "restic_last_backup_timestamp_seconds";
    check = "restic_last_check_timestamp_seconds";
    # Opt-in per host through the registry's `backup.restoreTest` and
    # `backup.restoreDrill` flags.
    restoreTest = "restic_last_restore_test_timestamp_seconds";
    restoreDrill = "restore_drill_last_success_timestamp_seconds";
  };

  optional = cond: x: if cond then [ x ] else [ ];
in
{
  inherit metrics;

  # The timestamps a registry entry promises to report, in a fixed order.
  # Empty for a host without a `backup` entry.
  expectedFor =
    hostMeta:
    let
      backup = hostMeta.backup or null;
    in
    if backup == null then
      [ ]
    else
      [
        metrics.backup
        metrics.check
      ]
      ++ optional (backup.restoreTest or false) metrics.restoreTest
      ++ optional (backup.restoreDrill or false) metrics.restoreDrill;
}
