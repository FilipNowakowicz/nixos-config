{ lib, pkgs, ... }:
let
  # Apply each retention class from lib/backup-policy.nix to dated snapshots in
  # a scratch repository and compare the survivors with a hand-worked oracle.
  # The path list changes partway through the series, so a lost
  # `--group-by host` would keep the older group intact and fail here.
  #
  # Series: 1-20 Nov 2026 daily (paths a for 1-10, a+b for 11-20), plus
  # 15 Sep, 15 Jun, 15 Dec 2025 and 15 Dec 2024. ISO weeks end on 1, 8, 15
  # and 22 Nov. restic counts from the newest snapshot, not the clock.
  backupRetentionBehaviour =
    let
      policy = import ../../lib/backup-policy.nix;
      novDays = lib.genList (i: "2026-11-${lib.fixedWidthNumber 2 (i + 1)}") 20;
      older = [
        "2024-12-15"
        "2025-12-15"
        "2026-06-15"
        "2026-09-15"
      ];
      # critical: 14 daily keeps 7-20 Nov; 8 weekly adds 1 Nov and all four
      # older dates; monthly and yearly add nothing new.
      expected.critical = older ++ [ "2026-11-01" ] ++ lib.sublist 6 14 novDays;
      # standard: 7 daily keeps 14-20 Nov; 4 weekly adds 1 and 8 Nov
      # (15 Nov is already kept); 3 monthly adds 15 Sep and 15 Jun.
      expected.standard = [
        "2026-06-15"
        "2026-09-15"
        "2026-11-01"
        "2026-11-08"
      ]
      ++ lib.sublist 13 7 novDays;
      runClass = class: ''
        export RESTIC_REPOSITORY=$PWD/repo-${class}
        restic init --quiet
        for d in ${lib.escapeShellArgs older} ${lib.escapeShellArgs (lib.sublist 0 10 novDays)}; do
          restic backup --quiet --host fixture --time "$d 12:00:00" src/a
        done
        for d in ${lib.escapeShellArgs (lib.sublist 10 10 novDays)}; do
          restic backup --quiet --host fixture --time "$d 12:00:00" src/a src/b
        done
        restic forget --quiet ${lib.concatStringsSep " " policy.${class}}
        restic snapshots --json | jq -r '.[].time[:10]' | sort > kept-${class}
        printf '%s\n' ${lib.escapeShellArgs expected.${class}} | sort > want-${class}
        diff -u want-${class} kept-${class}
      '';
    in
    pkgs.runCommand "backup-retention-behaviour"
      {
        nativeBuildInputs = [
          pkgs.restic
          pkgs.jq
        ];
      }
      ''
        export RESTIC_PASSWORD=fixture HOME=$PWD
        mkdir -p src/a src/b
        echo a > src/a/file
        echo b > src/b/file
        ${runClass "critical"}
        ${runClass "standard"}
        touch $out
      '';
in
{
  checks.backup-retention-behaviour = backupRetentionBehaviour;
}
