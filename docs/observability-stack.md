# Observability Stack

`nixosModules.observability-stack` exposes the reusable LGTM profile from this
repo. It keeps the existing `profiles.observability` option tree so hosts that
already import the profile do not need a migration.

## Local single-node stack

Use this mode when Grafana, Loki, Mimir, Tempo, Prometheus, Alloy, and the
OpenTelemetry collector all run on one host.

```nix
{
  imports = [
    inputs.self.nixosModules.observability-stack
  ];

  profiles.observability = {
    enable = true;
    grafana = {
      enable = true;
      adminPasswordFile = config.sops.secrets.grafana_admin_password.path;
      secretKeyFile = config.sops.secrets.grafana_secret_key.path;
    };
    loki.enable = true;
    mimir.enable = true;
    tempo.enable = true;
    collectors = {
      metrics.enable = true;
      logs.enable = true;
      traces.enable = true;
    };
  };
}
```

Dashboards are declared under `profiles.observability.dashboards`. Built-in
dashboards default to disabled and can be enabled or replaced by host-level
configuration.

## Remote client mode

`nixosModules.observability-client` configures a host to ship metrics, logs, and
traces to a central stack. The domain, URL paths, username, group, and secret
backend are explicit options.

```nix
{
  imports = [
    inputs.self.nixosModules.observability-stack
    inputs.self.nixosModules.observability-client
  ];

  profiles.observability-client = {
    enable = true;
    remoteEndpoint = {
      host = "observability.example.ts.net";
      metricsPath = "/obs/mimir/api/v1/push";
      logsPath = "/obs/loki/loki/api/v1/push";
      tracesPath = "/obs/otlp/v1/traces";
    };
    ingestAuth = {
      username = "telemetry";
      group = "telemetry-ingest";
      passwordFile = config.age.secrets.observability-ingest-password.path;
      serviceEnvironmentFile = config.age.secrets.otel-env.path;
    };
  };
}
```

The client module does not create secrets itself. Declare the secret and the
`BASICAUTH_PASSWORD` environment file with sops-nix, agenix, or another backend
at the host boundary, then pass those paths into `ingestAuth`.
