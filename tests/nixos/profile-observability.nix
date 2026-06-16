# E2E tests for the observability profile.
# Test 1: Alloy -> Loki pipeline (unauthenticated local stack).
# Test 2: Prometheus remoteWrite with basic auth (verifies auth header is sent).
# Test 3: OTLP trace pipeline -> Tempo (verifies span is stored and queryable).
# Test 4: Prometheus remoteWrite -> local Mimir (verifies metric is queryable).
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
      # Local LGTM stack — Alloy ships journal logs to Loki.
      obs =
        { ... }:
        {
          imports = [ ../../modules/nixos/profiles/observability ];

          profiles.observability = {
            enable = true;
            loki.enable = true;
            collectors.logs.enable = true;
          };

          environment.systemPackages = [ pkgs.curl ];
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

          environment.systemPackages = [ pkgs.curl ];
        };

      # OTLP trace pipeline: otel-collector receives spans and forwards to local Tempo.
      obs_tempo =
        { ... }:
        {
          imports = [ ../../modules/nixos/profiles/observability ];

          profiles.observability = {
            enable = true;
            tempo.enable = true;
            collectors.traces.enable = true;
          };

          environment.systemPackages = [ pkgs.curl ];
        };

      # Local Mimir: Prometheus remote-writes scraped metrics to the local Mimir instance.
      obs_mimir =
        { ... }:
        {
          imports = [ ../../modules/nixos/profiles/observability ];

          profiles.observability = {
            enable = true;
            mimir.enable = true;
            collectors.metrics.enable = true;
            # remoteWriteURL defaults to null; with mimir.enable, Prometheus
            # remote-writes to the local Mimir instance at 127.0.0.1:9009.
          };

          environment.systemPackages = [ pkgs.curl ];
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

      # ── Test 3: OTLP trace pipeline -> Tempo ──────────────────────────────
      obs_tempo.start()
      obs_tempo.wait_for_unit("tempo.service")
      obs_tempo.wait_for_unit("opentelemetry-collector.service")

      obs_tempo.wait_until_succeeds("curl -fsS http://127.0.0.1:3200/ready", timeout=30)

      # Push a span with a known trace ID through the OTLP HTTP receiver.
      # wait_until_succeeds retries until the otel-collector port is accepting connections.
      obs_tempo.wait_until_succeeds(
          "curl -fsS -X POST http://127.0.0.1:14318/v1/traces"
          " -H 'Content-Type: application/json'"
          " -d '{\"resourceSpans\":[{\"resource\":{\"attributes\":["
          "{\"key\":\"service.name\",\"value\":{\"stringValue\":\"test\"}}]},"
          "\"scopeSpans\":[{\"spans\":[{\"traceId\":\"aabbccddeeff00112233445566778899\","
          "\"spanId\":\"0011223344556677\",\"name\":\"tempo-e2e-marker\","
          "\"kind\":1,\"startTimeUnixNano\":\"1000000000\","
          "\"endTimeUnixNano\":\"2000000000\",\"status\":{}}]}]}]}'",
          timeout=30,
      )

      obs_tempo.wait_until_succeeds(
          "curl -fsS http://127.0.0.1:3200/api/traces/aabbccddeeff00112233445566778899"
          " | grep -q 'tempo-e2e-marker'",
          timeout=90,
      )

      # ── Test 4: Prometheus remoteWrite -> local Mimir ─────────────────────
      obs_mimir.start()
      obs_mimir.wait_for_unit("mimir.service")
      obs_mimir.wait_for_unit("prometheus.service")

      obs_mimir.wait_until_succeeds("curl -fsS http://127.0.0.1:9009/ready", timeout=60)

      obs_mimir.wait_until_succeeds(
          "curl -fsS 'http://127.0.0.1:9009/prometheus/api/v1/query?query=up'"
          " | grep -q '\"job\"'",
          timeout=90,
      )
    '';
  }
