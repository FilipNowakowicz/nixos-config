# `lib.dashboards` and `lib.generators`

Two small, identifier-free pure-function libraries exposed as flake outputs so
they can be reused without importing any `hosts/` assembly. Neither references a
hostname, key, age identity, disk ID, or any other private value; both evaluate
with stock `nixpkgs.lib` and nothing else.

```nix
# flake.nix
{
  inputs.nixos-fleet.url = "github:FilipNowakowicz/nixos-config";

  outputs =
    { nixos-fleet, ... }:
    let
      dash = nixos-fleet.lib.dashboards;
      gen = nixos-fleet.lib.generators;
    in
    {
      # ... use dash / gen below ...
    };
}
```

## `lib.dashboards` — Grafana dashboards as typed Nix

Builders that turn small attrsets into Grafana panel/dashboard JSON, so a
dashboard can live in Nix (and be diffed, templated, and tested) instead of as
hand-maintained JSON. Imported with **no arguments** — it is a bare attrset of
functions.

```nix
let
  dash = nixos-fleet.lib.dashboards;
in
dash.mkDashboard {
  uid = "node-health";
  title = "Node health";
  panels = [
    (dash.timeseriesPanel {
      id = 1;
      title = "CPU idle";
      ds = dash.mimirDS;
      gridPos = dash.gridPos { y = 0; };
      targets = [
        (dash.target {
          expr = ''node_cpu_seconds_total{${dash.hostSelector "main"},mode="idle"}'';
          legendFormat = "idle";
        })
      ];
    })
  ];
}
```

Surface: `gridPos`, `datasource`/`mimirDS`/`lokiDS`/`tempoDS`, `hostSelector`,
`target`, `timeseriesPanel`, `statPanel`, `tablePanel`, `logsPanel`,
`mkDashboard`. The output is a plain attrset you serialize with
`builtins.toJSON` (or hand to `services.grafana` provisioning).

**Non-goals.** This is not a full Grafana schema. It encodes the panel/datasource
patterns this fleet actually uses (LGTM datasources, a fixed `schemaVersion`).
Anything it does not cover is expressed by passing through extra attrs, not by
growing the builder into a complete Grafana DSL.

## `lib.generators` — Nix attrsets to config-format text

Serializers for config formats that have no native Nix generator. Imported as a
function of `{ lib }`; the flake output is already applied with `nixpkgs.lib`,
so `nixos-fleet.lib.generators` is ready to use.

- `toAlloyHCL` — render a list of Grafana Alloy/River components to HCL text,
  with `ref` (unquoted expressions) and `nestedBlock` (sub-blocks).
- `nginx.proxyLocation` — a reverse-proxy `location` attrset (websockets, basic
  auth, `extraConfig`, arbitrary `extraOptions`).
- `systemd.timer` — the `OnCalendar` timer shape used by recurring maintenance
  jobs.

```nix
let
  gen = nixos-fleet.lib.generators;
in
gen.toAlloyHCL [
  {
    type = "loki.write";
    label = "default";
    body.endpoint.url = "http://loki:3100/loki/api/v1/push";
  }
]
```

**Non-goals.** `nginx.proxyLocation` is intentionally a thin shape, not a routing
DSL — keep one-off behavior in `extraConfig` rather than expanding it. The Alloy
renderer covers the component/attribute/block subset this fleet emits, not the
entire River grammar.

## Clean-clone validation

Both libraries have boundary tests that import the bare file with stock
`nixpkgs.lib` and assert output shape, proving they evaluate with zero fleet
context:

```bash
nix build .#checks.x86_64-linux.lib-dashboards
nix build .#checks.x86_64-linux.lib-generators
```

You can also inspect the live outputs directly:

```bash
nix eval --json .#lib.dashboards.gridPos --apply 'f: f {}'
nix eval .#lib.generators.toAlloyHCL --apply 'f: f []'
```
