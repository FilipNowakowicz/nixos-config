# `lib.acl`, `lib.dashboards`, and `lib.generators`

Three small, identifier-free pure-function libraries exposed as flake outputs so
they can be reused without importing any `hosts/` assembly. None references a
hostname, key, age identity, disk ID, or any other private value; all evaluate
with stock `nixpkgs.lib` and nothing else (`lib.acl` operates only on the
registry attrset you pass it).

```nix
# flake.nix
{
  inputs.nixos-fleet.url = "github:FilipNowakowicz/nixos-config";

  outputs =
    { nixos-fleet, ... }:
    let
      acl = nixos-fleet.lib.acl;
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

## `lib.acl` — Tailscale ACLs from a host registry

`lib.acl.mkAcl` derives a complete Tailscale ACL (`{ tagOwners; acls; }`) from a
host-registry attrset: each host's `tailscale.tag` becomes a tag owner, and its
`tailscale.acceptFrom` relationships become tag-to-tag `tag:src -> tag:dst:port`
rules. Rules are tag-to-tag (not per-FQDN) so new nodes join the right group
automatically, and it fails fast at eval if an `acceptFrom` references a tag no
host carries. Imported as a function of `{ lib }`; the flake output is already
applied with `nixpkgs.lib`.

```nix
let
  acl = nixos-fleet.lib.acl;
in
builtins.toJSON (acl.mkAcl {
  laptop.tailscale.tag = "workstation";
  server.tailscale = {
    tag = "server";
    acceptFrom.workstation = [ 22 443 ];
  };
})
```

This is the same generator behind `nix run .#tailscale-acl`; see
[`docs/tailscale-acl.md`](../tailscale-acl.md) for the full registry/ACL model
and [`docs/samples/tailscale-acl.sample.json`](../samples/tailscale-acl.sample.json)
for a committed sanitized output.

**Non-goals.** It emits only `tagOwners` and tag-to-tag `acls` plus one
break-glass `autogroup:admin` rule — no per-node ACLs, SSH rules, or
autogroups beyond admin. Express anything outside that shape directly in your
own `acl.hujson`.

## Clean-clone validation

Each library has a boundary test that imports the bare file with stock
`nixpkgs.lib` (and, for `acl`, a synthetic `example.ts.net` registry) and asserts
output shape, proving they evaluate with zero fleet context:

```bash
nix build .#checks.x86_64-linux.lib-acl
nix build .#checks.x86_64-linux.lib-dashboards
nix build .#checks.x86_64-linux.lib-generators
```

You can also inspect the live outputs directly:

```bash
nix eval --json .#lib.dashboards.gridPos --apply 'f: f {}'
nix eval .#lib.generators.toAlloyHCL --apply 'f: f []'
nix run .#tailscale-acl   # lib.acl.mkAcl over this fleet's registry
```
