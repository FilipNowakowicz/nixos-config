# Smoke test for the homeserver-gcp reverse-proxy routing and auth boundaries.
# Boots a stripped-down node that imports the real nginx module so location-block
# changes are caught automatically, but replaces sops-backed secrets with
# in-store test files and generates a throwaway self-signed TLS cert.
{
  nixpkgs,
  system,
  ...
}:
let
  pkgs = import nixpkgs { inherit system; };

  testFqdn = "homeserver-gcp.test";

  # SHA1 htpasswd entry for admin:test.
  testHtpasswd = pkgs.writeText "test-htpasswd" "admin:{SHA}qUqP5cyxm6YcTAhz05Hph5gvu9M=";

  testGrafanaPassword = pkgs.writeText "grafana-admin-pw" "test";
  # Grafana requires a secret key of at least 32 characters.
  testGrafanaSecretKey = pkgs.writeText "grafana-secret-key" "smoke-test-secret-key-padding!!!";
in
(import "${nixpkgs}/nixos/lib/testing-python.nix" {
  inherit system pkgs;
}).runTest
  {
    name = "homeserver-gcp-smoke";

    nodes.server =
      { pkgs, lib, ... }:
      {
        imports = [
          ../../hosts/homeserver-gcp/nginx.nix
          ../../modules/nixos/profiles/observability
        ];

        profiles.homeserverGcpNginx = {
          enable = true;
          fqdn = testFqdn;
          ingestHtpasswdFile = testHtpasswd;
          grafanaAuthRequestUrl = "http://127.0.0.1:3180/auth";
        };

        profiles.observability = {
          enable = true;
          grafana = {
            enable = true;
            adminPasswordFile = testGrafanaPassword;
            secretKeyFile = testGrafanaSecretKey;
          };
          loki.enable = true;
          tempo.enable = true;
          mimir.enable = true;
          collectors = {
            metrics.enable = true;
            traces.enable = true;
            blackbox = {
              enable = true;
              probes = {
                vaultwarden-root = {
                  url = "https://${testFqdn}/";
                  expectedStatusCodes = [
                    200
                    301
                    302
                  ];
                  skipTLSVerify = true;
                };
                grafana-auth-boundary = {
                  url = "https://${testFqdn}/grafana/";
                  expectedStatusCodes = [ 200 ];
                  skipTLSVerify = true;
                };
              };
            };
          };
        };

        services = {
          grafana.settings."auth.proxy" = {
            enabled = true;
            header_name = "X-WEBAUTH-USER";
            header_property = "email";
            auto_sign_up = true;
            sync_ttl = 0;
            whitelist = "127.0.0.1";
            headers = "Name:X-WEBAUTH-NAME Role:X-WEBAUTH-ROLE Email:X-WEBAUTH-EMAIL";
          };
          grafana.settings.server = {
            domain = lib.mkForce testFqdn;
            root_url = "https://%(domain)s/grafana/";
            serve_from_sub_path = true;
          };

          vaultwarden = {
            enable = true;
            config = {
              ROCKET_ADDRESS = "127.0.0.1";
              ROCKET_PORT = 8222;
              SIGNUPS_ALLOWED = false;
              DOMAIN = "https://${testFqdn}";
            };
          };
        };

        # Generate a throwaway self-signed cert before nginx starts.
        systemd.services.smoke-test-tls-cert = {
          description = "Generate self-signed TLS cert for smoke test";
          before = [ "nginx.service" ];
          wantedBy = [ "nginx.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "gen-smoke-cert" ''
              mkdir -p /var/lib/nginx/certs
              ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 \
                -keyout /var/lib/nginx/certs/homeserver-gcp.key \
                -out /var/lib/nginx/certs/homeserver-gcp.crt \
                -days 1 -nodes -subj '/CN=${testFqdn}'
              chmod 640 /var/lib/nginx/certs/homeserver-gcp.key
              chown root:nginx /var/lib/nginx/certs/homeserver-gcp.key
            '';
          };
        };

        systemd.services.smoke-test-grafana-auth = {
          description = "Stub Grafana auth_request helper";
          wantedBy = [ "multi-user.target" ];
          before = [ "nginx.service" ];
          serviceConfig = {
            ExecStart = pkgs.writeShellScript "smoke-test-grafana-auth" ''
              exec ${pkgs.python3}/bin/python - <<'PY'
              from http.server import BaseHTTPRequestHandler, HTTPServer

              class Handler(BaseHTTPRequestHandler):
                  def do_GET(self):
                      self.send_response(204)
                      self.send_header("X-Auth-Request-User", "viewer@example.com")
                      self.send_header("X-Auth-Request-Email", "viewer@example.com")
                      self.send_header("X-Auth-Request-Name", "Smoke Viewer")
                      self.send_header("X-Auth-Request-Role", "Viewer")
                      self.end_headers()

                  def log_message(self, fmt, *args):
                      pass

              HTTPServer(("127.0.0.1", 3180), Handler).serve_forever()
              PY
            '';
            Restart = "always";
          };
        };

        networking.hosts."127.0.0.1" = [ testFqdn ];

        environment.systemPackages = [
          pkgs.curl
          pkgs.python3
        ];
      };

    testScript = builtins.concatStringsSep "\n" [
      "import os"
      ""
      "assert os.path.exists('/dev/kvm'), \\"
      "  \"KVM not available: /dev/kvm missing. Smoke tests require KVM acceleration.\""
      ""
      "start_all()"
      ""
      "server.wait_for_unit(\"vaultwarden.service\")"
      "server.wait_for_unit(\"grafana.service\")"
      "server.wait_for_unit(\"prometheus.service\")"
      "server.wait_for_unit(\"opentelemetry-collector.service\")"
      "server.wait_for_unit(\"prometheus-blackbox-exporter.service\")"
      "server.wait_for_unit(\"smoke-test-grafana-auth.service\")"
      "server.wait_for_unit(\"nginx.service\")"
      ""
      "# / -> Vaultwarden reachable (200 or redirect to login)"
      "server.wait_until_succeeds("
      "  \"curl -sk https://${testFqdn}/ -o /dev/null -w '%{http_code}'\""
      "  \" | grep -qE '^(200|301|302)'\","
      "  timeout=30,"
      ")"
      ""
      "# /grafana/ -> Grafana sub-path routing works"
      "server.wait_until_succeeds("
      "  \"curl -sk https://${testFqdn}/grafana/ -o /dev/null -w '%{http_code}'\""
      "  \" | grep -q '^200'\","
      "  timeout=90,"
      ")"
      ""
      "# Vaultwarden notification websocket route is explicit and reaches the upstream."
      "server.succeed("
      "  \"config=$(systemctl cat nginx.service\""
      "  \" | sed -n \\\"s#.*-c \\\\([^ ]*nginx\\\\.conf\\\\).*#\\\\1#p\\\"\""
      "  \" | tr -d \\\"'\\\\\\\"\\\"\""
      "  \" | head -n 1)\""
      "  \" && grep -q 'location = /notifications/hub' \\\"$config\\\"\""
      ")"
      ""
      "# Exact ingest routes require credentials."
      "ingest_paths = ["
      "    \"/obs/loki/loki/api/v1/push\","
      "    \"/obs/mimir/api/v1/push\","
      "    \"/obs/otlp/v1/traces\","
      "]"
      "for path in ingest_paths:"
      "    server.succeed("
      "      f\"curl -sk https://${testFqdn}{path} -o /dev/null -w '%{{http_code}}'\""
      "      f\" | grep -q '^401'\""
      "    )"
      ""
      "# Authenticated ingest reaches a backend instead of nginx's auth or deny fallback."
      "for path in ingest_paths:"
      "    server.succeed("
      "      f\"curl -sk -X POST -u admin:test https://${testFqdn}{path} -o /dev/null -w '%{{http_code}}'\""
      "      f\" | grep -qEv '^(401|404|502)$'\""
      "    )"
      ""
      "# Broader observability APIs are denied even with ingest credentials."
      "for path in ["
      "    \"/obs/loki/\","
      "    \"/obs/loki/loki/api/v1/query\","
      "    \"/obs/mimir/\","
      "    \"/obs/mimir/prometheus/api/v1/query\","
      "    \"/obs/otlp/\","
      "]:"
      "    server.succeed("
      "      f\"curl -sk -u admin:test https://${testFqdn}{path} -o /dev/null -w '%{{http_code}}'\""
      "      f\" | grep -q '^404'\""
      "    )"
      ""
      "server.wait_until_succeeds("
      "  '''python3 - <<\\'PY\\'"
      "import json"
      "import urllib.request"
      ""
      "for probe in (\"vaultwarden-root\", \"grafana-auth-boundary\"):"
      "    with urllib.request.urlopen("
      "        \"http://127.0.0.1:9090/api/v1/query?query=probe_success%7Bprobe%3D%22\""
      "        + probe"
      "        + \"%22%7D\""
      "    ) as response:"
      "        payload = json.load(response)"
      "    result = payload[\"data\"][\"result\"]"
      "    assert result, probe"
      "    assert result[0][\"value\"][1] == \"1\", (probe, result)"
      "PY''',"
      "  timeout=90,"
      ")"
      ""
    ];
  }
