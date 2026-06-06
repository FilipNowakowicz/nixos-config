{
  pkgs,
  hostMeta,
  ...
}:
let
  inherit (hostMeta) tailnetFQDN;
  eventStreamPort = 9273;
  statusEventStream = pkgs.writeText "homepage-status-events.py" ''
    import json
    import os
    import time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    STATUS_PATH = "/var/lib/homepage/public/status.json"
    PORT = ${toString eventStreamPort}


    class Handler(BaseHTTPRequestHandler):
      protocol_version = "HTTP/1.1"

      def log_message(self, format, *args):
        return

      def do_GET(self):
        if self.path != "/":
          self.send_response(404)
          self.end_headers()
          return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        last_event_id = self.headers.get("Last-Event-ID") or None
        keepalive = 0

        while True:
          try:
            stat_result = os.stat(STATUS_PATH)
            event_id = str(stat_result.st_mtime_ns)
            if event_id != last_event_id:
              with open(STATUS_PATH, "r", encoding="utf-8") as handle:
                payload = json.load(handle)
              body = json.dumps(
                {"generatedAt": payload.get("generatedAt")},
                separators=(",", ":"),
              )
              self.wfile.write(f"id: {event_id}\n".encode("utf-8"))
              self.wfile.write(b"event: status\n")
              self.wfile.write(f"data: {body}\n\n".encode("utf-8"))
              self.wfile.flush()
              last_event_id = event_id

            keepalive += 1
            if keepalive >= 15:
              self.wfile.write(b": keepalive\n\n")
              self.wfile.flush()
              keepalive = 0

            time.sleep(1)
          except (BrokenPipeError, ConnectionResetError):
            return
          except FileNotFoundError:
            time.sleep(1)
          except Exception:
            time.sleep(1)


    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
  '';
in
{
  systemd = {
    services.homepage-status = {
      description = "Generate read-only homepage status JSON";
      path = [
        pkgs.coreutils
        pkgs.curl
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

        prometheus_query_value() {
          local expr="$1"
          curl --silent --show-error --fail --get \
            --data-urlencode "query=$expr" \
            http://127.0.0.1:9009/prometheus/api/v1/query 2>/dev/null \
            | ${pkgs.jq}/bin/jq -r '
                if .status == "success" and (.data.result | length) > 0 then
                  (.data.result[0].value[1] | tonumber | floor)
                else
                  empty
                end
              ' 2>/dev/null || true
        }

        prometheus_query_label() {
          local expr="$1"
          local label="$2"
          curl --silent --show-error --fail --get \
            --data-urlencode "query=$expr" \
            http://127.0.0.1:9009/prometheus/api/v1/query 2>/dev/null \
            | ${pkgs.jq}/bin/jq -r --arg label "$label" '
                if .status == "success" and (.data.result | length) > 0 then
                  (.data.result[0].metric[$label] // empty)
                else
                  empty
                end
              ' 2>/dev/null || true
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
        main_restic_backup_ts="$(prometheus_query_value 'max(restic_last_backup_timestamp_seconds{host="main"})')"
        main_restic_check_ts="$(prometheus_query_value 'max(restic_last_check_timestamp_seconds{host="main"})')"
        lynis_ts="$(metric /var/lib/node-exporter-textfiles/lynis.prom lynis_scan_timestamp_seconds)"
        lynis_index="$(metric /var/lib/node-exporter-textfiles/lynis.prom lynis_hardening_index)"
        lynis_warnings="$(metric /var/lib/node-exporter-textfiles/lynis.prom lynis_warnings_total)"
        vulnix_ts="$(metric /var/lib/node-exporter-textfiles/vulnix.prom vulnix_scan_timestamp_seconds)"
        homeserver_revision="$(cat /run/current-system/configuration-revision 2>/dev/null || true)"
        homeserver_activated_at="$(metric /var/lib/node-exporter-textfiles/system_metadata.prom nixos_system_activated_at_seconds)"
        main_system_revision="$(prometheus_query_label 'max by (revision) (nixos_system_revision_info{host="main"})' revision)"
        main_system_activated_at="$(prometheus_query_value 'max(nixos_system_activated_at_seconds{host="main"})')"
        failed_units_json="$(systemctl --failed --plain --no-legend --no-pager | awk '{ print $1 }' | ${pkgs.jq}/bin/jq -R . | ${pkgs.jq}/bin/jq -s -c .)"
        tailscale_status_json="$(${pkgs.tailscale}/bin/tailscale status --json 2>/dev/null || printf '{}')"
        tailnet_devices_json="$(printf '%s' "$tailscale_status_json" | ${pkgs.jq}/bin/jq -c '
          def clean_dns:
            if . == null then null else sub("[.]$"; "") end;

          ([
            {
              name: (.Self.HostName // "homeserver-gcp"),
              dnsName: ((.Self.DNSName // null) | clean_dns),
              online: (.Self.Online // false),
              os: (.Self.OS // null),
              self: true
            }
          ] + (
            (.Peer // {})
            | to_entries
            | map(.value)
            | map({
              name: (.HostName // (.DNSName // "unknown")),
              dnsName: ((.DNSName // null) | clean_dns),
              online: (.Online // false),
              os: (.OS // null),
              self: false,
              lastSeen: (
                if (.LastSeen // "") == "0001-01-01T00:00:00Z" then null else (.LastSeen // null) end
              )
            })
          ))
          | sort_by(.name | ascii_downcase)
        ')"
        homeserver_online="$(tailscale_online_json homeserver-gcp)"
        main_online="$(tailscale_online_json main)"

        tmp="/var/lib/homepage/public/status.json.tmp"
        badge_tmp="/var/lib/homepage/public/status.svg.tmp"
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
          --argjson mainBackupAge "$(age_json "$main_restic_backup_ts")" \
          --argjson mainCheckAge "$(age_json "$main_restic_check_ts")" \
          --argjson lynisAge "$(age_json "$lynis_ts")" \
          --argjson lynisIndex "$(number_json "$lynis_index")" \
          --argjson lynisWarnings "$(number_json "$lynis_warnings")" \
          --argjson vulnixAge "$(age_json "$vulnix_ts")" \
          --arg homeserverRevision "$homeserver_revision" \
          --argjson homeserverActivatedAt "$(number_json "$homeserver_activated_at")" \
          --arg mainRevision "$main_system_revision" \
          --argjson mainActivatedAt "$(number_json "$main_system_activated_at")" \
          --argjson failedUnits "$failed_units_json" \
          --argjson tailnetDevices "$tailnet_devices_json" \
          '{
            generatedAt: $generatedAt,
            failedUnits: $failedUnits,
            tailnet: {
              devices: $tailnetDevices
            },
            hosts: {
              "homeserver-gcp": {
                fqdn: $fqdn,
                tailscale: {
                  online: $homeserverOnline,
                  state: $tailscaleState
                },
                system: (
                  {}
                  + (if $homeserverRevision == "" then {} else { revision: $homeserverRevision } end)
                  + (if $homeserverActivatedAt == null then {} else { activatedAt: $homeserverActivatedAt } end)
                ),
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
                    ageSeconds: $vulnixAge
                  }
                }
              },
              main: {
                tailscale: {
                  online: $mainOnline
                },
                system: (
                  {}
                  + (if $mainRevision == "" then {} else { revision: $mainRevision } end)
                  + (if $mainActivatedAt == null then {} else { activatedAt: $mainActivatedAt } end)
                ),
                backups: [
                  {
                    name: "local",
                    active: null,
                    timerState: null,
                    lastSuccessAgeSeconds: $mainBackupAge,
                    lastCheckAgeSeconds: $mainCheckAge
                  }
                ]
              }
            }
          }' > "$tmp"
        mv "$tmp" /var/lib/homepage/public/status.json
        chmod 0644 /var/lib/homepage/public/status.json

        read -r badge_mode badge_label badge_tracked <<EOF
        $(${pkgs.jq}/bin/jq -r '
          def service_values:
            [.hosts | to_entries[] | (.value.services // {} | to_entries[]) | .[]?];
          def backup_values:
            [.hosts | to_entries[] | (.value.backups // []) | .[]?];
          {
            tracked: (service_values | length),
            failedUnits: (.failedUnits | length),
            downServices: (service_values | map(select(.value.active == false)) | length),
            unknownServices: (service_values | map(select(.value.active == null)) | length),
            offlinePeers: ((.tailnet.devices // []) | map(select(.online == false)) | length),
            staleBackups: (backup_values | map(select((.lastSuccessAgeSeconds == null) or (.lastSuccessAgeSeconds > 93600))) | length)
          }
          | .mode = (
              if (.failedUnits > 0) or (.downServices > 0) or (.staleBackups > 0) then "alarm"
              elif (.unknownServices > 0) or (.offlinePeers > 0) then "watch"
              else "calm"
              end
            )
          | .label = (
              if .mode == "alarm" then "ALARM"
              elif .mode == "watch" then "WATCH"
              else "CALM"
              end
            )
          | "\(.mode)\t\(.label)\t\(.tracked)"
        ' /var/lib/homepage/public/status.json)
        EOF

        case "$badge_mode" in
          alarm)
            badge_fill="#d86958"
            badge_bg="#2a1715"
            ;;
          watch)
            badge_fill="#d9a44f"
            badge_bg="#2a2213"
            ;;
          *)
            badge_fill="#79c08f"
            badge_bg="#13251b"
            ;;
        esac

        cat >"$badge_tmp" <<EOF
        <svg xmlns="http://www.w3.org/2000/svg" width="180" height="32" viewBox="0 0 180 32" role="img" aria-label="Homepage status ''${badge_label}, ''${badge_tracked} tracked services">
          <rect width="180" height="32" rx="10" fill="#10120f"/>
          <rect x="1" y="1" width="178" height="30" rx="9" fill="''${badge_bg}" stroke="#2f352e"/>
          <circle cx="18" cy="16" r="6" fill="''${badge_fill}"/>
          <text x="31" y="20" fill="#f3efe3" font-family="ui-monospace, monospace" font-size="12" font-weight="700">''${badge_label}</text>
          <text x="166" y="20" fill="#d7d1c2" font-family="ui-monospace, monospace" font-size="11" text-anchor="end">''${badge_tracked} svc</text>
        </svg>
        EOF
        mv "$badge_tmp" /var/lib/homepage/public/status.svg
        chmod 0644 /var/lib/homepage/public/status.svg
      '';
      serviceConfig = {
        Type = "oneshot";
        RuntimeDirectory = "homepage-status";
      };
    };

    services.homepage-status-events = {
      description = "Stream homepage status updates over server-sent events";
      after = [ "homepage-status.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${statusEventStream}";
        Restart = "always";
        RestartSec = "2s";
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
