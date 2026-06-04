# Off-box liveness via a push-based dead-man's-switch.
#
# Every alerting component on this host (Mimir ruler, Alertmanager, the ntfy
# webhook) runs *on the host it is meant to watch*. If the VM stops, crashes, or
# hangs, none of them fire — the thing that fires alerts is inside the failure
# domain. This timer closes that gap from the opposite direction: it pings an
# external healthcheck endpoint on a fixed cadence, and the *external* service
# alerts when the pings stop. Because the ping originates inside the guest, this
# also catches in-guest hangs that a control-plane "instance != RUNNING" check
# would miss.
#
# The ping URL (e.g. a healthchecks.io check URL, which embeds a secret UUID and
# is configured with a grace period there) lives in sops as `heartbeat_ping_url`.
# A failed curl (host up, network/endpoint broken) leaves the local freshness
# metric stale, so the internal Mimir stack can still alert on a *degraded*
# heartbeat while the host lives; total host death is caught externally.
{ config, pkgs, ... }:
let
  inherit (config.lib.profiles.observability) mkPromScript;
in
{
  systemd = {
    services.heartbeat-ping = {
      description = "Push-based dead-man's-switch heartbeat ping";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        LoadCredential = [ "ping_url:${config.sops.secrets.heartbeat_ping_url.path}" ];
        # --retry rides out brief network blips so a transient failure does not
        # trip the external grace window; --fail makes HTTP errors non-zero so
        # ExecStartPost (and thus the freshness stamp) is skipped on failure.
        ExecStart = pkgs.writeShellScript "heartbeat-ping" ''
          set -eu
          url=$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/ping_url")
          ${pkgs.curl}/bin/curl -fsS --retry 3 --retry-delay 5 --max-time 30 -o /dev/null "$url"
        '';
        ExecStartPost = mkPromScript {
          name = "heartbeat.prom";
          lines = [
            "# HELP heartbeat_last_ping_timestamp_seconds Unix timestamp of last successful external heartbeat ping"
            "# TYPE heartbeat_last_ping_timestamp_seconds gauge"
            "heartbeat_last_ping_timestamp_seconds $(${pkgs.coreutils}/bin/date +%s)"
          ];
        };
      };
    };

    timers.heartbeat-ping = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "3min";
        # No RandomizedDelaySec: the external grace window is tuned to a fixed
        # cadence, so jitter would only widen the worst-case detection time.
        Persistent = false;
      };
    };
  };
}
