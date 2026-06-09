{ pkgs, ... }:
{
  # ── Identity ────────────────────────────────────────────────────────────
  # Fake hostname and a `.example.` placeholder domain — never a real tailnet
  # FQDN, cloud project ID, or other live identifier.
  networking.hostName = "server-example";
  system.stateVersion = "26.05";

  # ── Disks ───────────────────────────────────────────────────────────────
  # No real `/dev/disk/by-id/*` here either — see the workstation host for why.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  # ── A minimal hardened service ──────────────────────────────────────────
  # Demonstrates the exact `services.hardened.<name>.extraConfig` pattern from
  # docs/modules/services-hardened.md, evaluated against a real systemd unit.
  systemd.services.demo-app.serviceConfig = {
    ExecStart = "${pkgs.coreutils}/bin/true";
    Type = "oneshot";
  };

  services.hardened.demo-app.extraConfig = {
    CapabilityBoundingSet = "";
    ReadWritePaths = [ "/var/lib/demo-app" ];
  };

  # ── Remote observability client ─────────────────────────────────────────
  # No local Grafana/Loki/Mimir/Tempo — this host only ships telemetry to a
  # remote stack (layered in at the flake level via `observability-client`).
  # The endpoint below is an `.example.` placeholder, never a live tailnet host.
  profiles.observability-client = {
    enable = true;
    remoteEndpoint = {
      scheme = "https";
      host = "observability.example.ts.net";
      metricsPath = "/ingest/metrics";
      logsPath = "/ingest/logs";
      tracesPath = "/ingest/traces";
    };
    ingestAuth = {
      # "test-password" mirrors the fixture convention used throughout
      # `flake/checks.nix` — short enough to read as an obvious placeholder,
      # never a real credential (this whole tree is scanned by
      # `lib-scan-plaintext-secrets`).
      passwordFile = pkgs.writeText "demo-ingest-password" "test-password";
      serviceEnvironmentFile = pkgs.writeText "demo-otel-env" "BASICAUTH_PASSWORD=test-password";
    };
  };

  # ── Layering note ───────────────────────────────────────────────────────
  # `services-hardened`, `profiles.security`, and `observability-client` are
  # imported as public `nixosModules.*` outputs at the flake level (see
  # ../../flake.nix). This file only carries host-local facts: identity,
  # disks, and the one service this host actually runs.
}
