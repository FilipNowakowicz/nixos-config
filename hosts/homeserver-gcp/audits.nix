{
  config,
  lib,
  pkgs,
  ...
}:
let
  gen = import ../../lib/generators.nix { inherit lib; };
  inherit (gen.systemd) timer;
  inherit (config.lib.profiles.observability) mkPromScript;
in
{
  systemd = {
    services = {
      lynis-audit = {
        description = "Lynis security audit";
        # lynis shells out to bare tool names (ss, sysctl, getcap, lsmod, …) and
        # setuid wrappers (sudo, mount, ping). The NixOS service PATH omits both
        # /run/current-system/sw/bin and /run/wrappers/bin, so those probes
        # silently fail and the hardening index is badly under-reported (~58 vs
        # the real ~77). Give the audit the same tool path an interactive login
        # has so the metric reflects reality.
        path = [
          "/run/wrappers/bin"
          config.system.path
        ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "lynis-audit" ''
            report=/tmp/lynis-report.dat

            ${pkgs.lynis}/bin/lynis audit system \
              --quiet --no-colors --report-file "$report" 2>/dev/null
            rc=$?
            # lynis exits 0 (clean) or non-zero on warnings — treat all as success
            # if the report file wasn't written, the scan itself failed
            if [ ! -f "$report" ]; then
              echo "lynis did not produce a report" >&2
              exit 1
            fi

            hardening_index=$(grep "^hardening_index=" "$report" | cut -d= -f2)
            warning_count=$(grep -c "^warning\\[\\]=" "$report" || true)
            suggestion_count=$(grep -c "^suggestion\\[\\]=" "$report" || true)
            : "''${hardening_index:=0}"
            export hardening_index warning_count suggestion_count
            ${mkPromScript {
              name = "lynis.prom";
              lines = [
                "# HELP lynis_hardening_index Security hardening index (0-100)"
                "# TYPE lynis_hardening_index gauge"
                "lynis_hardening_index $hardening_index"
                "# HELP lynis_warnings_total Number of lynis warnings"
                "# TYPE lynis_warnings_total gauge"
                "lynis_warnings_total $warning_count"
                "# HELP lynis_suggestions_total Number of lynis suggestions"
                "# TYPE lynis_suggestions_total gauge"
                "lynis_suggestions_total $suggestion_count"
                "# HELP lynis_scan_timestamp_seconds Unix timestamp of last successful audit"
                "# TYPE lynis_scan_timestamp_seconds gauge"
                "lynis_scan_timestamp_seconds $(${pkgs.coreutils}/bin/date +%s)"
              ];
            }}
            rm -f "$report"
          '';
        };
      };

      vulnix-scan = {
        description = "Vulnix scan freshness check for current system closure";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "vulnix-scan" ''
            # --system scans /run/current-system; -j = JSON output
            # NVD data is downloaded and cached in /var/cache/vulnix
            # vulnix exit codes: 0 = clean, 2 = CVEs found, other = error.
            # Live-host CVE counts are deliberately not exported: raw NVD/CPE
            # matches create noisy version churn, while CI scans the flake-built
            # closures and is the authoritative CVE gate.
            json=$(${pkgs.vulnix}/bin/vulnix -S -j --cache-dir /var/cache/vulnix 2>/dev/null)
            rc=$?
            if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
              echo "vulnix failed with exit code $rc" >&2
              exit "$rc"
            fi

            # validate JSON — if vulnix errored, output won't parse and we abort
            printf '%s' "$json" | ${pkgs.jq}/bin/jq -e 'type == "array"' >/dev/null || {
              echo "vulnix produced invalid output" >&2; exit 1;
            }

            ${mkPromScript {
              name = "vulnix.prom";
              lines = [
                "# HELP vulnix_scan_timestamp_seconds Unix timestamp of last successful scan"
                "# TYPE vulnix_scan_timestamp_seconds gauge"
                "vulnix_scan_timestamp_seconds $(${pkgs.coreutils}/bin/date +%s)"
              ];
            }}
          '';
        };
      };
    };

    timers = {
      lynis-audit = timer {
        schedule = "daily";
        jitter = "1h";
      };

      vulnix-scan = timer {
        schedule = "daily";
        jitter = "1h";
      };
    };

    tmpfiles.rules = [
      "d /var/cache/vulnix 0750 root root -"
    ];
  };
}
