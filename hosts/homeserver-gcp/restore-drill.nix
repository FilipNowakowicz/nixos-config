{ config, pkgs, ... }:
# Full-service restore drill (layer 6 automation).
#
# The daily restore canary (backups.nix) proves the B2 path round-trips a marker
# and that the Vaultwarden SQLite snapshot opens cleanly. It does *not* prove a
# whole service can be brought up from restored bytes. This module closes that
# gap: it restores Vaultwarden, Grafana, and AdGuard Home from the homeserver B2
# restic repository into an isolated scratch root and then *starts each service
# binary against the restored state*, asserting it actually comes up — not merely
# that files exist.
#
# Isolation contract (must never touch live homeserver-gcp service data):
#   - Every restore target is under a throwaway scratch dir wiped on each run;
#     the live /var/lib/{vaultwarden,grafana,private/AdGuardHome} are never
#     written to. `restic restore` is given an explicit --target scratch root.
#   - Each service is started via `systemd-run` as a transient unit with
#     PrivateNetwork=true, so it binds inside its own network namespace
#     (loopback only). That makes the live DNS:53 / Grafana / Vaultwarden
#     listeners impossible to collide with and blocks any egress from the
#     scratch instance. The probe runs inside the same namespace.
#   - The drill never enables, reloads, or stops any live unit.
#
# This complements — and does not replace — the daily canary, which keeps
# running on its own timer.
let
  inherit (config.lib.profiles.observability) mkPromScript;

  scratchRoot = "/var/lib/restore-drill";

  vaultwardenPkg = config.services.vaultwarden.package;
  vaultwardenWebVault = config.services.vaultwarden.webVaultPackage;
  grafanaPkg = config.services.grafana.package;
  adguardPkg = config.services.adguardhome.package;

  # Wait for an HTTP endpoint to return success, retrying for ~60s. Used inside
  # the per-service network namespace so it can only see the scratch instance.
  waitHttp = pkgs.writeShellScript "restore-drill-wait-http" ''
    set -eu
    url="$1"
    expect="''${2:-}"
    for _ in $(${pkgs.coreutils}/bin/seq 1 60); do
      body=$(${pkgs.curl}/bin/curl -fsS --max-time 5 "$url" 2>/dev/null) || { ${pkgs.coreutils}/bin/sleep 1; continue; }
      if [ -z "$expect" ] || printf '%s' "$body" | ${pkgs.gnugrep}/bin/grep -q "$expect"; then
        printf '%s' "$body"
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 1
    done
    echo "restore-drill: endpoint $url did not become healthy in time" >&2
    exit 1
  '';

  # Run one service-bring-up check in an isolated network namespace. The whole
  # check (start binary in background, probe loopback, tear down) executes as a
  # transient *service* unit so PrivateNetwork applies to both the service and
  # the probe — scope units (the `--scope` form) don't support namespacing
  # directives like PrivateNetwork= at all ("Unknown assignment"); only service
  # units carry the exec/sandbox context that implements them. `--wait --pipe`
  # blocks until the unit exits and forwards its stdio and exit code, so the
  # drill script still fails (and prints why) when a bring-up check fails.
  runIsolated = name: script: ''
    ${pkgs.systemd}/bin/systemd-run \
      --quiet \
      --pipe \
      --wait \
      --collect \
      -p PrivateNetwork=true \
      -p RuntimeMaxSec=180 \
      --unit="restore-drill-${name}-$$" \
      ${pkgs.writeShellScript "restore-drill-check-${name}" script}
  '';

  driveScript = pkgs.writeShellScript "restore-drill" ''
    set -eu

    repo=${config.sops.secrets.restic_repository.path}
    target=${scratchRoot}/scratch

    # Always start from a clean scratch root so a previous run cannot leak state
    # forward and so we never accumulate restored secrets on disk between runs.
    ${pkgs.coreutils}/bin/rm -rf ${scratchRoot}/scratch
    ${pkgs.coreutils}/bin/install -d -m 0700 "$target"
    trap '${pkgs.coreutils}/bin/rm -rf ${scratchRoot}/scratch' EXIT

    restic() {
      ${pkgs.restic}/bin/restic --repository-file="$repo" --no-cache "$@"
    }

    echo "restore-drill: restoring service state from B2 into $target"
    restic restore latest --target "$target" \
      --include /var/lib/vaultwarden \
      --include /var/lib/grafana \
      --include /var/lib/restic-staging/adguardhome

    # ── Vaultwarden ────────────────────────────────────────────────────────
    # Restored snapshot ships db.sqlite3.backup (consistent) but not the live
    # db.sqlite3 (excluded from backup). Promote the snapshot into the name
    # Vaultwarden opens, inside the scratch tree only.
    vw_data="$target/var/lib/vaultwarden"
    ${pkgs.coreutils}/bin/cp "$vw_data/db.sqlite3.backup" "$vw_data/db.sqlite3"

    echo "restore-drill: starting Vaultwarden against restored data"
    ${runIsolated "vaultwarden" ''
      set -eu
      DATA_FOLDER="${scratchRoot}/scratch/var/lib/vaultwarden" \
      WEB_VAULT_FOLDER="${vaultwardenWebVault}/share/vaultwarden/vault" \
      ROCKET_ADDRESS=127.0.0.1 \
      ROCKET_PORT=18222 \
      ROCKET_LOG=critical \
      SIGNUPS_ALLOWED=false \
      ${vaultwardenPkg}/bin/vaultwarden &
      vw_pid=$!
      trap '${pkgs.coreutils}/bin/kill "$vw_pid" 2>/dev/null || true' EXIT
      ${waitHttp} http://127.0.0.1:18222/alive >/dev/null
      echo "restore-drill: Vaultwarden answered /alive from restored data"
    ''}

    # ── Grafana ────────────────────────────────────────────────────────────
    # Restored snapshot ships grafana.db.backup (consistent); promote it into
    # grafana.db inside scratch so Grafana opens the recovered database.
    gf_data="$target/var/lib/grafana"
    ${pkgs.coreutils}/bin/cp "$gf_data/grafana.db.backup" "$gf_data/grafana.db"

    echo "restore-drill: starting Grafana against restored data"
    ${runIsolated "grafana" ''
      set -eu
      data="${scratchRoot}/scratch/var/lib/grafana"
      cfg=$(${pkgs.coreutils}/bin/mktemp)
      ${pkgs.coreutils}/bin/cat >"$cfg" <<EOF
      [server]
      http_addr = 127.0.0.1
      http_port = 13030
      [paths]
      data = $data
      logs = $data/log
      [analytics]
      reporting_enabled = false
      check_for_updates = false
      [security]
      disable_initial_admin_creation = true
      EOF
      ${grafanaPkg}/bin/grafana server -homepath ${grafanaPkg}/share/grafana -config "$cfg" &
      gf_pid=$!
      trap '${pkgs.coreutils}/bin/kill "$gf_pid" 2>/dev/null || true' EXIT
      # /api/health returns {"database":"ok",...} only once the DB opened cleanly.
      ${waitHttp} http://127.0.0.1:13030/api/health '"database": "ok"' >/dev/null \
        || ${waitHttp} http://127.0.0.1:13030/api/health '"database":"ok"' >/dev/null
      echo "restore-drill: Grafana reported database ok from restored data"
    ''}

    # ── AdGuard Home ───────────────────────────────────────────────────────
    # Staged backup lives at /var/lib/restic-staging/adguardhome (the public
    # state tree). The restored config keeps the live bind (0.0.0.0:53), which
    # is safe only because the namespace is private: nothing else lives there.
    ag_work="$target/var/lib/restic-staging/adguardhome"

    # First prove the restored config parses (catches a torn/garbage config
    # before we attempt a full bring-up). --check-config mutates the file in
    # place, but only the scratch copy.
    ${adguardPkg}/bin/AdGuardHome \
      --work-dir "$ag_work" \
      --config "$ag_work/AdGuardHome.yaml" \
      --check-config --no-check-update

    echo "restore-drill: starting AdGuard Home against restored data"
    ${runIsolated "adguardhome" ''
      set -eu
      work="${scratchRoot}/scratch/var/lib/restic-staging/adguardhome"
      # Keep the restored config's own DNS bind (0.0.0.0:53). Safe only because
      # PrivateNetwork gives this instance its own loopback-only namespace, so it
      # cannot collide with the live AdGuard DNS listener. Move the web UI off
      # its configured port to a fixed scratch port we control.
      ${adguardPkg}/bin/AdGuardHome \
        --work-dir "$work" \
        --config "$work/AdGuardHome.yaml" \
        --web-addr 127.0.0.1:13003 \
        --no-check-update --no-permcheck &
      ag_pid=$!
      trap '${pkgs.coreutils}/bin/kill "$ag_pid" 2>/dev/null || true' EXIT

      # First confirm the web server is serving the restored instance. The
      # /control/* API is auth-gated, but /login.html is a public route, so a
      # 200 here proves the HTTP server bound and started.
      ${waitHttp} http://127.0.0.1:13003/login.html >/dev/null

      # Then prove the DNS engine itself came up from the restored config: query
      # the local resolver. With no upstream reachable inside the namespace the
      # answer may be SERVFAIL, but *any* DNS response (dig exit 0) proves the
      # resolver is listening and processing — a dead engine would time out.
      for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
        if ${pkgs.dnsutils}/bin/dig +tries=1 +time=2 @127.0.0.1 -p 53 health.adguardhome.restore-drill.invalid >/dev/null 2>&1; then
          echo "restore-drill: AdGuard Home web UI + DNS engine up from restored data"
          exit 0
        fi
        ${pkgs.coreutils}/bin/sleep 1
      done
      echo "restore-drill: AdGuard Home DNS engine did not answer in time" >&2
      exit 1
    ''}

    # All three services came up from restored bytes — stamp the freshness
    # metric last (set -eu means any failure above skips this and leaves the
    # metric stale for RestoreDrillStale to catch).
    ${mkPromScript {
      name = "restore_drill.prom";
      lines = [
        "# HELP restore_drill_last_success_timestamp_seconds Unix timestamp of last successful full-service restore drill (Vaultwarden + Grafana + AdGuard Home brought up from B2-restored state)"
        "# TYPE restore_drill_last_success_timestamp_seconds gauge"
        "restore_drill_last_success_timestamp_seconds $(${pkgs.coreutils}/bin/date +%s)"
      ];
    }}

    echo "restore-drill: full-service restore drill PASSED"
  '';
in
{
  systemd = {
    services.restore-drill-b2 = {
      description = "Full-service restore drill (Vaultwarden + Grafana + AdGuard Home) from B2";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # Explicitly not wantedBy any live target; this only ever runs from its
      # own timer or a manual `systemctl start restore-drill-b2.service`.
      environment.RESTIC_PASSWORD_FILE = config.sops.secrets.restic_password.path;
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = config.sops.secrets.b2_credentials.path;
        ExecStart = driveScript;
        # Drill restores real services and probes them; give it room but bound it.
        TimeoutStartSec = "20min";
      };
    };

    timers.restore-drill-b2 = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Quarterly: first day of Jan/Apr/Jul/Oct. The manual quarterly drill in
        # docs/restore-drill.md remains the human exercise; this is the
        # unattended proof between human drills.
        OnCalendar = "*-01,04,07,10-01 05:30:00";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    tmpfiles.rules = [
      "d ${scratchRoot} 0700 root root -"
    ];
  };
}
