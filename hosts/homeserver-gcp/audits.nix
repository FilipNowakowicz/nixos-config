{ lib, pkgs, ... }:
let
  gen = import ../../lib/generators.nix { inherit lib; };
  inherit (gen.systemd) timer;
in
{
  systemd = {
    services = {
      lynis-audit = {
        description = "Lynis security audit";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "lynis-audit" ''
            report=/tmp/lynis-report.dat
            tmp=/var/lib/node-exporter-textfiles/lynis.prom.tmp

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
            {
              echo "# HELP lynis_hardening_index Security hardening index (0-100)"
              echo "# TYPE lynis_hardening_index gauge"
              echo "lynis_hardening_index $hardening_index"
              echo "# HELP lynis_warnings_total Number of lynis warnings"
              echo "# TYPE lynis_warnings_total gauge"
              echo "lynis_warnings_total $warning_count"
              echo "# HELP lynis_suggestions_total Number of lynis suggestions"
              echo "# TYPE lynis_suggestions_total gauge"
              echo "lynis_suggestions_total $suggestion_count"
              echo "# HELP lynis_scan_timestamp_seconds Unix timestamp of last successful audit"
              echo "# TYPE lynis_scan_timestamp_seconds gauge"
              echo "lynis_scan_timestamp_seconds $(date +%s)"
            } > "$tmp"
            mv "$tmp" /var/lib/node-exporter-textfiles/lynis.prom
            rm -f "$report"
          '';
        };
      };

      vulnix-scan = {
        description = "Vulnix CVE scan of current system closure";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "vulnix-scan" ''
            whitelist=${./vulnix-whitelist.toml}
            tmp=/var/lib/node-exporter-textfiles/vulnix.prom.tmp

            # --system scans /run/current-system; -j = JSON output
            # NVD data is downloaded and cached in /var/cache/vulnix
            # vulnix exit codes: 0 = clean, 2 = CVEs found, other = error
            json=$(${pkgs.vulnix}/bin/vulnix -S -j \
              --whitelist "$whitelist" \
              --cache-dir /var/cache/vulnix 2>/dev/null) || true

            # validate JSON — if vulnix errored, output won't parse and we abort
            pkg_count=$(printf '%s' "$json" | ${pkgs.jq}/bin/jq 'length // 0') || {
              echo "vulnix produced invalid output" >&2; exit 1;
            }
            cve_count=$(printf '%s' "$json" | ${pkgs.jq}/bin/jq '[.[].affected_by | length] | add // 0')

            {
              echo "# HELP vulnix_affected_packages_total Packages with known CVEs after whitelist"
              echo "# TYPE vulnix_affected_packages_total gauge"
              echo "vulnix_affected_packages_total $pkg_count"
              echo "# HELP vulnix_cve_total CVE findings after whitelist"
              echo "# TYPE vulnix_cve_total gauge"
              echo "vulnix_cve_total $cve_count"
              echo "# HELP vulnix_scan_timestamp_seconds Unix timestamp of last successful scan"
              echo "# TYPE vulnix_scan_timestamp_seconds gauge"
              echo "vulnix_scan_timestamp_seconds $(date +%s)"
            } > "$tmp"
            mv "$tmp" /var/lib/node-exporter-textfiles/vulnix.prom
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
