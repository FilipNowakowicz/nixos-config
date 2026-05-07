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

  # SHA1 htpasswd entry for admin:test — only needs to be parseable by nginx;
  # the test verifies 401 on unauthenticated requests, not successful auth.
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
      { pkgs, ... }:
      {
        imports = [
          ../../hosts/homeserver-gcp/nginx.nix
          ../../modules/nixos/profiles/observability
        ];

        profiles.homeserverGcpNginx = {
          enable = true;
          fqdn = testFqdn;
          ingestHtpasswdFile = testHtpasswd;
        };

        profiles.observability = {
          enable = true;
          grafana = {
            enable = true;
            adminPasswordFile = testGrafanaPassword;
            secretKeyFile = testGrafanaSecretKey;
          };
          loki.enable = true;
          mimir.enable = true;
        };

        services.vaultwarden = {
          enable = true;
          config = {
            ROCKET_ADDRESS = "127.0.0.1";
            ROCKET_PORT = 8222;
            SIGNUPS_ALLOWED = false;
            DOMAIN = "https://${testFqdn}";
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

        networking.hosts."127.0.0.1" = [ testFqdn ];

        environment.systemPackages = [ pkgs.curl ];
      };

    testScript = ''
      import os
      assert os.path.exists('/dev/kvm'), \
        "KVM not available: /dev/kvm missing. Smoke tests require KVM acceleration."

      start_all()

      server.wait_for_unit("vaultwarden.service")
      server.wait_for_unit("grafana.service")
      server.wait_for_unit("nginx.service")

      # / → Vaultwarden reachable (200 or redirect to login)
      server.wait_until_succeeds(
        "curl -sk https://${testFqdn}/ -o /dev/null -w '%{http_code}'"
        " | grep -qE '^(200|301|302)'",
        timeout=30,
      )

      # /grafana/ → Grafana sub-path routing works
      server.wait_until_succeeds(
        "curl -sk https://${testFqdn}/grafana/ -o /dev/null -w '%{http_code}'"
        " | grep -q '^200'",
        timeout=30,
      )

      # /obs/* → 401 without credentials (auth boundary enforced, not 404/502)
      for path in ["/obs/loki/", "/obs/mimir/", "/obs/otlp/"]:
          server.succeed(
            f"curl -sk https://${testFqdn}{path} -o /dev/null -w '%{{http_code}}'"
            f" | grep -q '^401'"
          )
    '';
  }
