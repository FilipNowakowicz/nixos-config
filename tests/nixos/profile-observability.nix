# E2E tests for the observability profile.
# Test 1: Alloy -> Loki pipeline (unauthenticated local stack).
# Test 2: Prometheus remoteWrite with basic auth (verifies auth header is sent).
# Test 3: Local metrics, infrastructure rules and Alertmanager discovery.
{
  nixpkgs,
  system,
}:
let
  pkgs = import nixpkgs { inherit system; };
in
(import "${nixpkgs}/nixos/lib/testing-python.nix" {
  inherit system pkgs;
}).runTest
  {
    name = "profile-observability";

    nodes = {
      # Local log stack — Alloy ships journal logs to Loki.
      obs =
        { ... }:
        {
          imports = [ ../../modules/nixos/profiles/observability ];

          profiles.observability = {
            enable = true;
            loki.enable = true;
            collectors.logs.enable = true;
            collectors.metrics.enable = true;
            alerts.enable = true;
          };

          environment.systemPackages = [
            pkgs.curl
            pkgs.python3
          ];
        };

      # Client-side auth path — Prometheus remoteWrite with basic_auth.
      # Uses a stub HTTPS echo server; verifies the Authorization header is present.
      obs_auth =
        { pkgs, ... }:
        {
          imports = [ ../../modules/nixos/profiles/observability ];

          profiles.observability = {
            enable = true;
            collectors.metrics = {
              enable = true;
              remoteWriteURL = "http://127.0.0.1:19090/api/v1/push";
            };
            ingestAuth = {
              username = "telemetry";
              # Use a plain file — no sops needed in a test node.
              passwordFile = pkgs.writeText "obs-test-password" "test-secret";
            };
          };

          # HTTP stub: responds 204 so Prometheus doesn't back off, appends headers to file.
          systemd.services.stub-ingest = {
            description = "Stub ingest endpoint that captures Authorization headers";
            wantedBy = [ "multi-user.target" ];
            script = ''
                            mkdir -p /tmp/stub
                            ${pkgs.python3}/bin/python3 - <<'EOF'
              import http.server

              class Handler(http.server.BaseHTTPRequestHandler):
                  def do_POST(self):
                      with open("/tmp/stub/last-request", "a") as f:
                          f.write(str(self.headers))
                      self.send_response(204)
                      self.end_headers()
                  def log_message(self, *a): pass

              http.server.HTTPServer(("127.0.0.1", 19090), Handler).serve_forever()
              EOF
            '';
            serviceConfig = {
              Restart = "always";
              Type = "simple";
            };
          };

          environment.systemPackages = [
            pkgs.curl
            pkgs.python3
          ];
        };

    };

    testScript = ''
      # ── Test 1: Alloy -> Loki ──────────────────────────────────────────────
      obs.start()
      obs.wait_for_unit("loki.service")
      obs.wait_for_unit("alloy.service")

      obs.wait_until_succeeds("curl -fsS http://127.0.0.1:3100/ready", timeout=30)

      obs.succeed("logger -t nixos-profile-test 'alloy-loki-e2e-marker'")

      obs.wait_until_succeeds(
          "NOW=$(date +%s);"
          " curl -fsS -G http://127.0.0.1:3100/loki/api/v1/query_range"
          " --data-urlencode 'query={job=\"systemd-journal\"}'"
          " --data-urlencode \"start=$((NOW - 300))000000000\""
          " --data-urlencode \"end=''${NOW}000000000\""
          " --data-urlencode 'limit=100'"
          " | grep -q 'alloy-loki-e2e-marker'",
          timeout=90,
      )

      # ── Test 2: Prometheus remoteWrite sends Authorization header ──────────
      obs_auth.start()
      obs_auth.wait_for_unit("stub-ingest.service")
      obs_auth.wait_for_unit("prometheus.service")

      # Wait for Prometheus to complete a scrape+remoteWrite cycle (15s interval + startup).
      # The stub responds 204 so Prometheus doesn't back off between attempts.
      obs_auth.wait_until_succeeds(
          "grep -q 'Authorization: Basic' /tmp/stub/last-request",
          timeout=90,
      )
      obs_auth.succeed(
          "auth=$(grep -m1 '^Authorization: Basic ' /tmp/stub/last-request | awk '{print $3}' | tr -d '\\r'); "
          "test \"$(printf '%s' \"$auth\" | base64 -d)\" = 'telemetry:test-secret'"
      )

      # ── Test 3: Metrics and alert evaluation ───────────────────────────────
      obs.wait_for_unit("prometheus.service")
      obs.wait_for_unit("alertmanager.service")
      obs.wait_until_succeeds(
          "curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22node%22%7D'"
          " | python3 -c 'import json,sys; r=json.load(sys.stdin)[\"data\"][\"result\"]; assert r and r[0][\"value\"][1] == \"1\"'",
          timeout=90,
      )
      obs.succeed("curl -fsS http://127.0.0.1:9090/api/v1/rules | grep -q SystemdUnitFailed")
      obs.wait_until_succeeds(
          "curl -fsS http://127.0.0.1:9090/api/v1/alertmanagers | grep -q '127.0.0.1:9093'",
          timeout=30,
      )
    '';
  }
