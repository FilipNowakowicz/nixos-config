{
  pkgs,
  hostMeta,
  ...
}:
let
  inherit (hostMeta) tailnetFQDN;
in
{
  systemd = {
    services.homepage-status = {
      description = "Generate read-only homepage status JSON";
      path = [
        pkgs.coreutils
        pkgs.gawk
        pkgs.gnugrep
        pkgs.jq
        pkgs.systemd
      ];
      script = ''
        set -eu

        mkdir -p /var/lib/homepage/public
        now="$(date +%s)"

        metric() {
          local file="$1"
          local name="$2"
          awk -v metric="$name" '$1 == metric { print $2; found = 1 } END { exit found ? 0 : 1 }' "$file" 2>/dev/null || true
        }

        age_json() {
          local timestamp="$1"
          if [ -n "$timestamp" ] && [ "$timestamp" -eq "$timestamp" ] 2>/dev/null; then
            printf '%s' "$((now - timestamp))"
          else
            printf 'null'
          fi
        }

        number_json() {
          local value="$1"
          if [ -n "$value" ] && printf '%s' "$value" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
            printf '%s' "$value"
          else
            printf 'null'
          fi
        }

        bool_json() {
          local value="$1"
          if [ "$value" = "true" ] || [ "$value" = "false" ]; then
            printf '%s' "$value"
          else
            printf 'null'
          fi
        }

        service_state() {
          local unit="$1"
          if systemctl is-active --quiet "$unit"; then
            printf active
          elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            printf inactive
          else
            printf unavailable
          fi
        }

        timer_state() {
          local unit="$1"
          if systemctl is-active --quiet "$unit"; then
            printf active
          elif systemctl list-timers --all --no-legend "$unit" 2>/dev/null | grep -q .; then
            printf inactive
          else
            printf unavailable
          fi
        }

        service_active_json() {
          local unit="$1"
          if systemctl is-active --quiet "$unit"; then
            printf true
          elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            printf false
          else
            printf null
          fi
        }

        tailscale_online_json() {
          local host="$1"
          printf '%s' "$tailscale_status_json" | ${pkgs.jq}/bin/jq -c --arg host "$host" '
            if (.Self.HostName // "") == $host then
              (.Self.Online // false)
            else
              (
                (.Peer // {})
                | to_entries
                | map(.value)
                | map(select(
                    (.HostName // "") == $host
                    or ((.DNSName // "") | startswith($host + "."))
                  ))
                | if length > 0 then (.[0].Online // false) else false end
              )
            end
          '
        }

        restic_backup_ts="$(metric /var/lib/node-exporter-textfiles/restic_backup.prom restic_last_backup_timestamp_seconds)"
        restic_check_ts="$(metric /var/lib/node-exporter-textfiles/restic_check.prom restic_last_check_timestamp_seconds)"
        lynis_ts="$(metric /var/lib/node-exporter-textfiles/lynis.prom lynis_scan_timestamp_seconds)"
        lynis_index="$(metric /var/lib/node-exporter-textfiles/lynis.prom lynis_hardening_index)"
        lynis_warnings="$(metric /var/lib/node-exporter-textfiles/lynis.prom lynis_warnings_total)"
        vulnix_ts="$(metric /var/lib/node-exporter-textfiles/vulnix.prom vulnix_scan_timestamp_seconds)"
        vulnix_cves="$(metric /var/lib/node-exporter-textfiles/vulnix.prom vulnix_cve_total)"
        vulnix_packages="$(metric /var/lib/node-exporter-textfiles/vulnix.prom vulnix_affected_packages_total)"
        failed_units_json="$(systemctl --failed --plain --no-legend --no-pager | awk '{ print $1 }' | ${pkgs.jq}/bin/jq -R . | ${pkgs.jq}/bin/jq -s -c .)"
        tailscale_status_json="$(${pkgs.tailscale}/bin/tailscale status --json 2>/dev/null || printf '{}')"
        homeserver_online="$(tailscale_online_json homeserver-gcp)"
        main_online="$(tailscale_online_json main)"

        tmp="/var/lib/homepage/public/status.json.tmp"
        ${pkgs.jq}/bin/jq -n \
          --argjson generatedAt "$now" \
          --arg fqdn "${tailnetFQDN}" \
          --argjson homeserverOnline "$(bool_json "$homeserver_online")" \
          --argjson mainOnline "$(bool_json "$main_online")" \
          --arg tailscaleState "$(service_state tailscaled.service)" \
          --arg resticBackupState "$(service_state restic-backups-b2.service)" \
          --arg resticBackupTimer "$(timer_state restic-backups-b2.timer)" \
          --arg resticCheckTimer "$(timer_state restic-check-b2.timer)" \
          --arg lynisTimer "$(timer_state lynis-audit.timer)" \
          --arg vulnixTimer "$(timer_state vulnix-scan.timer)" \
          --argjson adguardActive "$(service_active_json adguardhome.service)" \
          --argjson nginxActive "$(service_active_json nginx.service)" \
          --argjson vaultwardenActive "$(service_active_json vaultwarden.service)" \
          --argjson grafanaActive "$(service_active_json grafana.service)" \
          --argjson lokiActive "$(service_active_json loki.service)" \
          --argjson mimirActive "$(service_active_json mimir.service)" \
          --argjson tempoActive "$(service_active_json tempo.service)" \
          --argjson backupAge "$(age_json "$restic_backup_ts")" \
          --argjson checkAge "$(age_json "$restic_check_ts")" \
          --argjson lynisAge "$(age_json "$lynis_ts")" \
          --argjson lynisIndex "$(number_json "$lynis_index")" \
          --argjson lynisWarnings "$(number_json "$lynis_warnings")" \
          --argjson vulnixAge "$(age_json "$vulnix_ts")" \
          --argjson vulnixCves "$(number_json "$vulnix_cves")" \
          --argjson vulnixPackages "$(number_json "$vulnix_packages")" \
          --argjson failedUnits "$failed_units_json" \
          '{
            generatedAt: $generatedAt,
            failedUnits: $failedUnits,
            hosts: {
              "homeserver-gcp": {
                fqdn: $fqdn,
                tailscale: {
                  online: $homeserverOnline,
                  state: $tailscaleState
                },
                services: {
                  adguard: { active: $adguardActive, unit: "adguardhome.service" },
                  nginx: { active: $nginxActive, unit: "nginx.service" },
                  vaultwarden: { active: $vaultwardenActive, unit: "vaultwarden.service" },
                  grafana: { active: $grafanaActive, unit: "grafana.service" },
                  loki: { active: $lokiActive, unit: "loki.service" },
                  mimir: { active: $mimirActive, unit: "mimir.service" },
                  tempo: { active: $tempoActive, unit: "tempo.service" }
                },
                backups: [
                  {
                    name: "b2",
                    active: ($resticBackupState == "active"),
                    timerState: $resticBackupTimer,
                    lastSuccessAgeSeconds: $backupAge,
                    lastCheckAgeSeconds: $checkAge
                  }
                ],
                audits: {
                  lynis: {
                    timerState: $lynisTimer,
                    ageSeconds: $lynisAge,
                    hardeningIndex: $lynisIndex,
                    warningsTotal: $lynisWarnings
                  },
                  vulnix: {
                    timerState: $vulnixTimer,
                    ageSeconds: $vulnixAge,
                    cveTotal: $vulnixCves,
                    affectedPackagesTotal: $vulnixPackages
                  }
                }
              },
              main: {
                tailscale: {
                  online: $mainOnline
                }
              }
            }
          }' > "$tmp"
        mv "$tmp" /var/lib/homepage/public/status.json
        chmod 0644 /var/lib/homepage/public/status.json
      '';
      serviceConfig = {
        Type = "oneshot";
        RuntimeDirectory = "homepage-status";
      };
    };

    timers.homepage-status = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "1m";
        Persistent = true;
      };
    };

    tmpfiles.rules = [
      "d /var/lib/homepage/public 0755 root nginx -"
      "C /var/lib/homepage/public/index.html 0644 root nginx - ${pkgs.writeText "homepage-placeholder.html" ''
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Homepage not deployed</title>
            <style>
              body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #10120f; color: #f3efe3; font-family: sans-serif; }
              main { max-width: 42rem; padding: 2rem; }
              code { color: #e0b15b; }
            </style>
          </head>
          <body>
            <main>
              <h1>Homepage assets not deployed yet</h1>
              <p>Deploy the homepage site into <code>/var/lib/homepage/public</code>.</p>
              <p>The live status endpoint is still available at <code>/home/status.json</code>.</p>
            </main>
          </body>
        </html>
      ''}"
    ];
  };
}
