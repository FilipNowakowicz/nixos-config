# Observability Stack

`nixosModules.observability-stack` exposes the reusable monitoring profile from this
repo. It keeps the existing `profiles.observability` option tree so hosts that
already import the profile do not need a migration.

## Importing from your own flake

Add this flake as an input and import the module(s) you need:

```nix
# flake.nix
{
  inputs.nixos-fleet.url = "github:FilipNowakowicz/nixos-config";

  outputs =
    {
      nixpkgs,
      nixos-fleet,
      ...
    }:
    {
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          nixos-fleet.nixosModules.observability-stack
          nixos-fleet.nixosModules.observability-client
          ./configuration.nix
        ];
      };
    };
}
```

Or, inside a module that already receives `inputs`:

```nix
{
  imports = [
    inputs.nixos-fleet.nixosModules.observability-stack
    inputs.nixos-fleet.nixosModules.observability-client
  ];
}
```

## Local single-node stack

Use this mode when Grafana, Loki, Prometheus, Alertmanager and Alloy all run on one host.

```nix
{
  imports = [
    inputs.nixos-fleet.nixosModules.observability-stack
  ];

  profiles.observability = {
    enable = true;
    grafana = {
      enable = true;
      adminPasswordFile = config.sops.secrets.grafana_admin_password.path;
      secretKeyFile = config.sops.secrets.grafana_secret_key.path;
    };
    loki.enable = true;
    alerts.enable = true;
    collectors = {
      metrics.enable = true;
      logs.enable = true;
    };
  };
}
```

Dashboards are declared under `profiles.observability.dashboards`. Built-in
dashboards default to disabled and can be enabled or replaced by host-level
configuration.

## Remote client mode

`nixosModules.observability-client` configures a host to ship metrics and logs to a central stack. The domain, URL paths, username, group, and secret
backend are explicit options.

```nix
{
  imports = [
    inputs.nixos-fleet.nixosModules.observability-stack
    inputs.nixos-fleet.nixosModules.observability-client
  ];

  profiles.observability-client = {
    enable = true;
    remoteEndpoint = {
      host = "observability.example.ts.net";
      metricsPath = "/obs/prometheus/api/v1/write";
      logsPath = "/obs/loki/loki/api/v1/push";
    };
    ingestAuth = {
      username = "telemetry";
      group = "telemetry-ingest";
      passwordFile = config.age.secrets.observability-ingest-password.path;
    };
  };
}
```

The client module does not create secrets itself. Declare the password secret with sops-nix, agenix, or another backend
at the host boundary, then pass that path into `ingestAuth`.

## Decision: minimal personal-server stack

Issue [#474](https://github.com/FilipNowakowicz/nixos-config/issues/474),
following the homeserver design review (#459), removes **Mimir, Tempo and the
OpenTelemetry collector**, including the OTLP trace pipeline. Keep **Prometheus
as the single metrics store, Loki, Grafana, Alloy for logs, node and blackbox
exporters, AdGuard, the GitHub recovery runner, and NixOS rather than containers**.
The tailnet DNS policy is unchanged.

This is a small personal server. Only Grafana and AdGuard application data are
backed up independently; multiple telemetry backends add failure modes and
upkeep without corresponding value. There are no applications producing useful
traces, and one server does not need horizontally scalable metrics storage.
Mimir's ring configuration caused a boot crash loop during the GCP project move.
Revisit only with a new reason: several hosts needing shared long-term metrics
beyond one Prometheus, or a self-written service requiring distributed tracing.
The `observabilityStaysMinimal` invariant checks every registry host and rejects
`services.mimir`, `services.tempo` or `services.opentelemetry-collector` enablement.
Their names remain only here and in that guard and its regression tests.

### Migration and manual cleanup (after a separately authorized deployment)

No deployment or cleanup is performed by this change. Prometheus now keeps 30
days on the homeserver, accepts remote write through the exact authenticated
`/obs/prometheus/api/v1/write` nginx route, evaluates the shared infrastructure
rules, and delivers them to the loopback Alertmanager with the existing
`alertmanager_webhook_url`. Clients retain a 24-hour local buffer. Metrics
history from the removed backend is not imported; the existing Prometheus TSDB
supplies its recent local samples and new remote writes accumulate from cutover.

Treat alert continuity as a migration gate, not just a successful system switch:

1. Before the production switch, arrange an overlapping independent evaluator
   and notification receiver using the same rules and off-host webhook. Keep
   the old evaluation/delivery path active until that overlap has been tested
   end to end; the off-box heartbeat and direct failed-unit notifier remain
   enabled throughout. Do not rely on the heartbeat as a substitute for rules.
2. Switch the homeserver first; confirm `/api/v1/rules` on `127.0.0.1:9090`
   contains every infrastructure rule, `/api/v1/alertmanagers` discovers
   `127.0.0.1:9093`, and send a controlled test alert through to the real
   notification target. Keep overlap through rule `for` periods and verify
   pending/firing alerts; pending state and silences do not migrate automatically.
3. Switch `main` to the new authenticated ingest path, then confirm its samples
   with `up{host="main"}` at the receiver and inspect remote-write failures and
   pending samples. Pause or roll back if delivery fails. If rolling back the
   server, roll back the client route together; do not retire the overlap until
   both metrics and notifications have been verified. This PR is not authority
   to merge or trigger the existing automatic production deployment.
4. Once the new stack is verified and rollback no longer needs the old data,
   manually inspect then remove `/var/lib/mimir`, `/var/lib/tempo`, and any
   corresponding `/var/lib/private/mimir`, `/var/lib/private/tempo` and retired
   collector state (including `/var/lib/private/opentelemetry-collector`, if
   present). Confirm the retired units are absent/inactive and the paths are
   not mount points before removal. Never remove `/var/lib/prometheus2`,
   `/var/lib/alertmanager`, `/var/lib/loki`, `/var/lib/grafana` or AdGuard state.
   No activation script automatically deletes data.

The `otel-env` template is removed from `main`. Its input
`observability_ingest_password` remains required by Prometheus and Alloy;
no encrypted secret becomes unused, and encrypted files are unchanged.
Grafana's provisioned datasource list prunes retired datasources on restart;
all metrics panels reference the new Prometheus UID.
