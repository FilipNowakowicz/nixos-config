{ config, pkgs, ... }:
let
  inherit (config.systemd) defaultUnit;
  units = config.environment.etc."systemd/system".source;
  analyze = "${config.systemd.package}/bin/systemd-analyze";

  # Two services ordered after each other: verify must report this, or it did
  # not really run and the check would pass for nothing.
  canary = pkgs.runCommand "boot-ordering-canary-units" { } ''
    mkdir $out
    for pair in a:b b:a; do
      printf '[Unit]\nDefaultDependencies=no\nAfter=canary-%s.service\n[Service]\nExecStart=%s\n' \
        "''${pair#*:}" ${pkgs.coreutils}/bin/true >"$out/canary-''${pair%:*}.service"
    done
    printf '[Unit]\nDefaultDependencies=no\nWants=canary-a.service canary-b.service\n' >$out/canary.target
  '';
in
{
  # Fail the host build when its boot transaction has an ordering cycle.
  # systemd breaks a cycle at boot by deleting an arbitrary job in it, so a
  # cycle can pass every other check and only show up when the job it happens
  # to drop matters (#542: a nixpkgs bump plus one After= left main's
  # tailscaled unstarted). `systemd-analyze verify` builds the same start
  # transaction offline from the generated unit directory. The sandbox has no
  # /run/systemd, so it runs as a user manager; cycle detection is the same.
  system.checks = [
    (pkgs.runCommand "${config.networking.hostName}-boot-ordering-cycles" { } ''
      export HOME=$TMPDIR XDG_RUNTIME_DIR=$TMPDIR
      verify() {
        SYSTEMD_UNIT_PATH=$1 ${analyze} --user verify --man=no "$2" 2>&1 | grep -i "ordering cycle" || true
      }
      if [ -z "$(verify ${canary} canary.target)" ]; then
        echo "systemd-analyze verify did not report the canary cycle; it is not checking anything" >&2
        exit 1
      fi
      found=$(verify ${units} ${defaultUnit})
      if [ -n "$found" ]; then
        printf '%s\n' "$found" >&2
        echo "boot ordering cycle in ${defaultUnit}" >&2
        exit 1
      fi
      touch $out
    '')
  ];
}
