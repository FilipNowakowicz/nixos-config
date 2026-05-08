{
  config,
  lib,
  pkgs,
  inputs,
  hostMeta,
  ...
}:
let
  inherit (hostMeta) tailnetFQDN;
  dash = import ../../lib/dashboards.nix;
  textfileDir = "/var/lib/node-exporter-textfiles";
  homepageDir = "/var/lib/homepage/public";
  homepagePlaceholder = pkgs.writeText "homepage-placeholder.html" ''
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
          <p>Build the dashboard with <code>nix build '.#packages.x86_64-linux.inventory'</code>, then copy the result contents into <code>/var/lib/homepage/public</code>.</p>
          <p>The live status endpoint is still available at <code>/home/status.json</code>.</p>
        </main>
      </body>
    </html>
  '';
in
{
  imports = [
    inputs.disko.nixosModules.disko
    ./hardware-configuration.nix
    ./disko.nix
    ./nginx.nix
    ./adguard.nix
    ../../modules/nixos/profiles/base.nix
    ../../modules/nixos/profiles/machine-common.nix
    ../../modules/nixos/profiles/security.nix
    ../../modules/nixos/profiles/sops-base.nix
    ../../modules/nixos/profiles/user.nix
  ];

  systemd = {
    services = {
      restic-backups-b2 = {
        serviceConfig.ExecStartPost = pkgs.writeShellScript "restic-backup-metrics" ''
          tmp=${textfileDir}/restic_backup.prom.tmp
          {
            echo "# HELP restic_last_backup_timestamp_seconds Unix timestamp of last successful restic backup"
            echo "# TYPE restic_last_backup_timestamp_seconds gauge"
            echo "restic_last_backup_timestamp_seconds $(date +%s)"
          } > "$tmp"
          mv "$tmp" ${textfileDir}/restic_backup.prom
        '';
      };

      restic-check-b2 = {
        description = "Restic B2 repository integrity check";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        environment = {
          RESTIC_REPOSITORY = "b2:filipnowakowicz-gcp:";
          RESTIC_PASSWORD_FILE = config.sops.secrets.restic_password.path;
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.restic}/bin/restic check --read-data-subset=1G";
          ExecStartPost = pkgs.writeShellScript "restic-check-metrics" ''
            tmp=${textfileDir}/restic_check.prom.tmp
            {
              echo "# HELP restic_last_check_timestamp_seconds Unix timestamp of last successful restic integrity check"
              echo "# TYPE restic_last_check_timestamp_seconds gauge"
              echo "restic_last_check_timestamp_seconds $(date +%s)"
            } > "$tmp"
            mv "$tmp" ${textfileDir}/restic_check.prom
          '';
          EnvironmentFile = config.sops.secrets.b2_credentials.path;
        };
      };

      homepage-status = {
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

          mkdir -p ${homepageDir}
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

          restic_backup_ts="$(metric ${textfileDir}/restic_backup.prom restic_last_backup_timestamp_seconds)"
          restic_check_ts="$(metric ${textfileDir}/restic_check.prom restic_last_check_timestamp_seconds)"
          lynis_ts="$(metric ${textfileDir}/lynis.prom lynis_scan_timestamp_seconds)"
          lynis_index="$(metric ${textfileDir}/lynis.prom lynis_hardening_index)"
          lynis_warnings="$(metric ${textfileDir}/lynis.prom lynis_warnings_total)"
          vulnix_ts="$(metric ${textfileDir}/vulnix.prom vulnix_scan_timestamp_seconds)"
          vulnix_cves="$(metric ${textfileDir}/vulnix.prom vulnix_cve_total)"
          vulnix_packages="$(metric ${textfileDir}/vulnix.prom vulnix_affected_packages_total)"
          failed_units_json="$(systemctl --failed --plain --no-legend --no-pager | awk '{ print $1 }' | jq -R . | jq -s -c .)"

          tmp="${homepageDir}/status.json.tmp"
          jq -n \
            --arg host "homeserver-gcp" \
            --arg fqdn "${tailnetFQDN}" \
            --argjson generatedAt "$now" \
            --arg nginx "$(service_state nginx.service)" \
            --arg vaultwarden "$(service_state vaultwarden.service)" \
            --arg grafana "$(service_state grafana.service)" \
            --arg adguard "$(service_state adguardhome.service)" \
            --arg tailscale "$(service_state tailscaled.service)" \
            --arg resticBackup "$(service_state restic-backups-b2.service)" \
            --arg loki "$(service_state loki.service)" \
            --arg mimir "$(service_state mimir.service)" \
            --arg tempo "$(service_state tempo.service)" \
            --arg resticCheckTimer "$(timer_state restic-check-b2.timer)" \
            --arg lynisTimer "$(timer_state lynis-audit.timer)" \
            --arg vulnixTimer "$(timer_state vulnix-scan.timer)" \
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
              host: $host,
              fqdn: $fqdn,
              services: {
                nginx: $nginx,
                vaultwarden: $vaultwarden,
                grafana: $grafana,
                adguard: $adguard,
                tailscale: $tailscale,
                resticBackup: $resticBackup,
                loki: $loki,
                mimir: $mimir,
                tempo: $tempo
              },
              timers: {
                resticCheck: $resticCheckTimer,
                lynis: $lynisTimer,
                vulnix: $vulnixTimer
              },
              metrics: {
                resticBackupAgeSeconds: $backupAge,
                resticCheckAgeSeconds: $checkAge,
                lynisAgeSeconds: $lynisAge,
                lynisHardeningIndex: $lynisIndex,
                lynisWarningsTotal: $lynisWarnings,
                vulnixAgeSeconds: $vulnixAge,
                vulnixCveTotal: $vulnixCves,
                vulnixAffectedPackagesTotal: $vulnixPackages
              },
              failedUnits: $failedUnits
            }' > "$tmp"
          mv "$tmp" ${homepageDir}/status.json
          chmod 0644 ${homepageDir}/status.json
        '';
        serviceConfig = {
          Type = "oneshot";
          RuntimeDirectory = "homepage-status";
        };
      };

      lynis-audit = {
        description = "Lynis security audit";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "lynis-audit" ''
            report=/tmp/lynis-report.dat
            tmp=${textfileDir}/lynis.prom.tmp

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
            warning_count=$(grep -c "^warning\[\]=" "$report" || true)
            suggestion_count=$(grep -c "^suggestion\[\]=" "$report" || true)
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
            mv "$tmp" ${textfileDir}/lynis.prom
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
            tmp=${textfileDir}/vulnix.prom.tmp

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
            mv "$tmp" ${textfileDir}/vulnix.prom
          '';
        };
      };

      tailscale-cert = {
        description = "Fetch TLS certificate from Tailscale";
        wantedBy = [ "multi-user.target" ];
        after = [
          "tailscaled.service"
          "network-online.target"
        ];
        wants = [ "network-online.target" ];
        script = ''
          for attempt in {1..60}; do
            ${pkgs.tailscale}/bin/tailscale status > /dev/null 2>&1 && break
            [ $attempt -lt 60 ] && sleep 1
          done
          mkdir -p /var/lib/tailscale/certs
          ${pkgs.tailscale}/bin/tailscale cert \
            --cert-file /var/lib/tailscale/certs/homeserver-gcp.crt \
            --key-file /var/lib/tailscale/certs/homeserver-gcp.key \
            ${tailnetFQDN}
          # /var/lib/tailscale is root:root 700; copy certs to a path nginx can read
          mkdir -p /var/lib/nginx/certs
          install -m 644 /var/lib/tailscale/certs/homeserver-gcp.crt /var/lib/nginx/certs/homeserver-gcp.crt
          install -m 640 -g nginx /var/lib/tailscale/certs/homeserver-gcp.key /var/lib/nginx/certs/homeserver-gcp.key
          if ${pkgs.systemd}/bin/systemctl is-active --quiet nginx.service; then
            ${pkgs.systemd}/bin/systemctl reload nginx.service
          fi
        '';
        serviceConfig = {
          Type = "oneshot";
          TimeoutStartSec = 120;
        };
      };

      nginx = {
        after = [ "tailscale-cert.service" ];
        requires = [ "tailscale-cert.service" ];
      };
    };

    timers = {
      lynis-audit = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
          RandomizedDelaySec = "1h";
        };
      };

      vulnix-scan = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
          RandomizedDelaySec = "1h";
        };
      };

      restic-check-b2 = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "weekly";
          Persistent = true;
          RandomizedDelaySec = "2h";
        };
      };

      homepage-status = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2m";
          OnUnitActiveSec = "1m";
          Persistent = true;
        };
      };

      tailscale-cert = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
          RandomizedDelaySec = "1h";
        };
      };
    };
  };

  system = {
    stateVersion = "24.11";

    activationScripts = {
      # On first boot the SSH host key doesn't exist yet, so sops can't decrypt secrets.
      # This activation script fetches the pre-baked key from GCE instance metadata
      # (injected by OpenTofu at VM creation) before sops-nix runs.
      injectGceSshHostKey = ''
        if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
          mkdir -p /etc/ssh
          _tmpkey=$(${pkgs.coreutils}/bin/mktemp -p /run)
          _fetched=0
          for _i in 1 2 3 4 5; do
            if ${pkgs.curl}/bin/curl -sf --max-time 5 \
              -H "Metadata-Flavor: Google" \
              "http://metadata.google.internal/computeMetadata/v1/instance/attributes/ssh-host-key-b64" \
              2>/dev/null \
              | ${pkgs.coreutils}/bin/base64 -d > "$_tmpkey" 2>/dev/null; then
              _fetched=1
              break
            fi
            sleep 2
          done
          if [ "$_fetched" = "1" ] && [ -s "$_tmpkey" ]; then
            install -m 600 "$_tmpkey" /etc/ssh/ssh_host_ed25519_key
            ${pkgs.openssh}/bin/ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key > /etc/ssh/ssh_host_ed25519_key.pub
            chmod 644 /etc/ssh/ssh_host_ed25519_key.pub
          fi
          rm -f "$_tmpkey"
        fi
      '';

      setupSecrets.deps = lib.mkAfter [ "injectGceSshHostKey" ];
      setupSecretsForUsers.deps = lib.mkAfter [ "injectGceSshHostKey" ];

    };
  };

  # Passwordless sudo is safe here: access is SSH-key-only over Tailscale,
  # no interactive console, and deploy-rs needs it for activation.
  security.sudo.wheelNeedsPassword = false;

  nix = {
    settings.trusted-users = lib.mkForce [ "root" ];
    settings.trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "main.local:fSo1pk+WU1RU7vpv+GTbzldKn4MMtBS46vQasXJ2oeQ="
    ];
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
  };

  environment.enableAllTerminfo = true;

  systemd.tmpfiles.rules = [
    "d ${homepageDir} 0755 root nginx -"
    "C ${homepageDir}/index.html 0644 root nginx - ${homepagePlaceholder}"
    "d /var/cache/vulnix 0750 root root -"
  ];

  networking = {
    hostName = "homeserver-gcp";
    firewall = {
      checkReversePath = "loose";
      interfaces.tailscale0.allowedTCPPorts = [
        22
        443
      ];
    };
  };

  boot = {
    loader.timeout = 1;
    kernelParams = [
      "console=tty1"
      "console=ttyS0,115200n8"
      "systemd.journald.forward_to_console=1"
    ];
  };

  profiles.observability = {
    enable = true;
    grafana = {
      enable = true;
      adminPasswordFile = config.sops.secrets.grafana_admin_password.path;
      secretKeyFile = config.sops.secrets.grafana_secret_key.path;
    };
    loki.enable = true;
    tempo.enable = true;
    mimir.enable = true;
    collectors = {
      metrics.enable = true;
      logs.enable = true;
      traces.enable = true;
    };
    dashboards = {
      fleet.enable = true;

      lynis = {
        enable = true;
        definition = dash.mkDashboard {
          uid = "homeserver-lynis";
          title = "Security Audit";
          panels = [
            (dash.timeseriesPanel {
              id = 1;
              title = "Hardening Index (0-100)";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 0;
                y = 0;
                w = 12;
                h = 8;
              };
              targets = [
                (dash.target {
                  expr = "lynis_hardening_index";
                  legendFormat = "hardening index";
                })
              ];
            })
            (dash.timeseriesPanel {
              id = 2;
              title = "Warnings";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 12;
                y = 0;
                w = 12;
                h = 8;
              };
              targets = [
                (dash.target {
                  expr = "lynis_warnings_total";
                  legendFormat = "warnings";
                })
              ];
            })
            (dash.timeseriesPanel {
              id = 3;
              title = "Audit Age (hours)";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 0;
                y = 8;
                w = 12;
                h = 8;
              };
              targets = [
                (dash.target {
                  expr = "(time() - lynis_scan_timestamp_seconds) / 3600";
                  legendFormat = "hours since last audit";
                })
              ];
            })
          ];
        };
      };

      cve = {
        enable = true;
        definition = dash.mkDashboard {
          uid = "homeserver-cve";
          title = "CVE Scan";
          panels = [
            (dash.timeseriesPanel {
              id = 1;
              title = "CVE Findings (after whitelist)";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 0;
                y = 0;
                w = 12;
                h = 8;
              };
              targets = [
                (dash.target {
                  expr = "vulnix_cve_total";
                  legendFormat = "CVEs";
                })
              ];
            })
            (dash.timeseriesPanel {
              id = 2;
              title = "Affected Packages (after whitelist)";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 12;
                y = 0;
                w = 12;
                h = 8;
              };
              targets = [
                (dash.target {
                  expr = "vulnix_affected_packages_total";
                  legendFormat = "packages";
                })
              ];
            })
            (dash.timeseriesPanel {
              id = 3;
              title = "Scan Age (hours)";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 0;
                y = 8;
                w = 12;
                h = 8;
              };
              targets = [
                (dash.target {
                  expr = "(time() - vulnix_scan_timestamp_seconds) / 3600";
                  legendFormat = "hours since last scan";
                })
              ];
            })
          ];
        };
      };

      backup = {
        enable = true;
        definition = dash.mkDashboard {
          uid = "homeserver-backup-health";
          title = "Backup Health";
          panels = [
            (dash.timeseriesPanel {
              id = 1;
              title = "Backup Age (hours)";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 0;
                y = 0;
                w = 12;
                h = 8;
              };
              targets = [
                (dash.target {
                  expr = "(time() - restic_last_backup_timestamp_seconds) / 3600";
                  legendFormat = "hours since last backup";
                })
              ];
            })
            (dash.timeseriesPanel {
              id = 2;
              title = "Check Age (hours)";
              ds = dash.mimirDS;
              gridPos = dash.gridPos {
                x = 12;
                y = 0;
                w = 12;
                h = 8;
              };
              targets = [
                (dash.target {
                  expr = "(time() - restic_last_check_timestamp_seconds) / 3600";
                  legendFormat = "hours since last check";
                })
              ];
            })
          ];
        };
      };
    };
  };

  services = {
    grafana.settings.server = {
      domain = lib.mkForce tailnetFQDN;
      root_url = "https://%(domain)s/grafana/";
      serve_from_sub_path = true;
    };

    restic.backups.b2 = {
      paths = [
        "/var/lib/vaultwarden"
        "/var/lib/grafana"
        "/var/lib/AdGuardHome"
      ];
      repository = "b2:filipnowakowicz-gcp:";
      passwordFile = config.sops.secrets.restic_password.path;
      environmentFile = config.sops.secrets.b2_credentials.path;
    };

    openssh = {
      enable = true;
      openFirewall = false;
    };

    tailscale = {
      enable = true;
      openFirewall = true;
      authKeyFile = config.sops.secrets.tailscale_auth_key.path;
    };

    journald.extraConfig = ''
      ForwardToConsole=yes
      MaxLevelConsole=info
    '';

    hardened = {
      tailscale-cert = {
        extraConfig = {
          ProtectHome = false;
          ReadWritePaths = [
            "/var/lib/tailscale"
            "/var/lib/nginx/certs"
          ];
          RestrictAddressFamilies = [ "AF_UNIX" ];
        };
      };

      nginx = {
        extraConfig = {
          CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";
          AmbientCapabilities = "CAP_NET_BIND_SERVICE";
          ReadWritePaths = [
            "/var/cache/nginx"
            "/var/log/nginx"
            "/var/lib/nginx/certs"
          ];
        };
      };

      vaultwarden = {
        extraConfig = {
          CapabilityBoundingSet = "";
          AmbientCapabilities = "";
          ReadWritePaths = [ "/var/lib/vaultwarden" ];
        };
      };
    };

    vaultwarden = {
      enable = true;
      config = {
        ROCKET_ADDRESS = "127.0.0.1";
        ROCKET_PORT = 8222;
        SIGNUPS_ALLOWED = false;
        DOMAIN = "https://${tailnetFQDN}";
      };
    };

  };

  profiles.homeserverGcpNginx = {
    enable = true;
    fqdn = tailnetFQDN;
    ingestHtpasswdFile = config.sops.secrets.observability_ingest_htpasswd.path;
  };

  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    secrets = {
      user_password.neededForUsers = true;
      tailscale_auth_key = { };
      grafana_admin_password = {
        owner = "grafana";
      };
      grafana_secret_key = {
        owner = "grafana";
      };
      observability_ingest_htpasswd = {
        owner = config.services.nginx.user;
        inherit (config.services.nginx) group;
      };
      restic_password = { };
      b2_credentials = { };
    };
  };

  users.users = {
    user = {
      home = "/home/user";
      hashedPasswordFile = config.sops.secrets.user_password.path;
    };
  };

}
