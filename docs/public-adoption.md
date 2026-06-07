# Public Adoption Plan

Goal: make this repository useful enough that strangers can learn from it,
reuse parts of it, and share it as a serious example of production-style NixOS
personal infrastructure.

Stars are an outcome, not an engineering requirement. The repository can earn
attention only if the public surface is easy to understand, safe to inspect, and
credible from a clean clone.

---

## Positioning

The strongest public story is not "my dotfiles". It is:

> A real multi-host NixOS fleet with reusable modules for hardening,
> observability, host inventory, Tailscale ACL generation, backup validation,
> runtime theming, and CI invariants.

That framing keeps the host assemblies honest while giving other users concrete
pieces to copy or import.

## Public Contract

Every reusable component should have the same minimum contract:

- a named flake output (`nixosModules.*`, `homeModules.*`, `packages.*`,
  `apps.*`, `templates.*`, or `checks.*`);
- a short public doc with usage, option boundaries, and non-goals;
- at least one clean-clone validation command;
- fixtures or tests that prove it works outside the personal host assembly;
- no dependency on private hostnames, keys, age identities, disk IDs, or
  credentials.

Anything without that contract may still be public as reference infrastructure,
but it should not be marketed as reusable.

## Release Tracks

### Track 1: Reusable Nix Modules

Priority components:

1. `nixosModules.services-hardened`
2. `nixosModules.observability-stack`
3. `nixosModules.observability-client`
4. `homeModules.runtime-theme`
5. host-registry helpers and generated Tailscale ACLs

Each should have examples that can be copied into a separate flake without
importing `hosts/`.

### Track 2: Clean-Clone Experience

A new visitor should be able to run these without secrets or hardware:

```bash
nix run .#doctor
nix run .#tailscale-acl
nix run .#inventory-json
nix build .#control-center
bash scripts/validate.sh light
```

The `doctor` output should explain failures in public-reader terms: missing
Nix, unsupported platform, dirty formatting, broken docs, or evaluation errors.

### Track 3: Example Fleet

Add a minimal example fleet under `examples/` once two or more reusable modules
need shared demonstration code. It should be intentionally fake:

- no real hostnames;
- no real disk IDs;
- no decryptable secrets;
- no live cloud project identifiers;
- one workstation-like host and one server-like host.

The example should show the layering pattern, not replace the real personal
fleet.

### Track 4: Shareable Artifacts

High-signal artifacts make the repo easier to link:

- a concise architecture diagram in the README;
- module docs with copyable examples;
- a generated inventory sample;
- a generated Tailscale ACL sample;
- a short "what to copy first" section for new NixOS users;
- screenshots only for real UI outputs such as `control-center`, not as the
  main selling point.

## Sample Artifacts

Two generated, sanitized samples are committed under `docs/samples/` so
visitors can see the shape of this fleet's generated outputs without cloning
and building:

- [`docs/samples/inventory.sample.json`](samples/inventory.sample.json) — one
  full host entry from `nix run .#inventory-json`, including the `drift` and
  `health` sub-objects.
- [`docs/samples/tailscale-acl.sample.json`](samples/tailscale-acl.sample.json) —
  the complete `nix run .#tailscale-acl` output.

### Why sanitize, and how it stays reproducible

`apps.tailscale-acl` only ever emits `tagOwners` and tag-to-tag `acls` (see
[`docs/tailscale-acl.md`](tailscale-acl.md)) — no hostnames, keys, or per-node
identifiers — so its sample is committed verbatim from `nix run .#tailscale-acl`.

`apps.inventory-json` does carry fleet-private values: real Nix store hash
prefixes in `closurePath` and this fleet's real Tailscale tailnet suffix in
`drift.tailnetFQDN` (see [`docs/host-registry.md`](host-registry.md)). Those are
the only two value shapes in the export that are private; everything else
(`name`, `system`, `services`, `health`, port lists, …) is already either public
fleet structure or copied from `lib/host-registry.nix`'s own `example.ts.net`
convention.

The sample is regenerated with a value-pattern substitution, not a hand edit,
so it stays reproducible against any clone regardless of that clone's real
identifiers:

```bash
nix run .#inventory-json | jq -S '
  .hosts |= [.[] | select(.name == "homeserver-gcp")]
  | .hosts |= map(
      .closurePath |= sub("/nix/store/[a-z0-9]{32}-";
                          "/nix/store/00000000000000000000000000000000-")
      | .drift.tailnetFQDN |= sub("\\.tail[0-9a-f]+\\.ts\\.net$"; ".example.ts.net")
    )
' > docs/samples/inventory.sample.json

nix run .#tailscale-acl | jq -S . > docs/samples/tailscale-acl.sample.json
```

The `jq` filter matches store-hash and tailnet-suffix _patterns_, not this
fleet's specific values, so running it again — here or against a fork with
different real identifiers — produces the same sanitized shape. Both commands
are checked by `lib-scan-plaintext-secrets` (`bash scripts/validate.sh light`),
which scans every tracked file for credential-shaped strings.

## Star Growth Checklist

Engineering work:

- keep the README front page focused on reusable value;
- expose reusable boundaries as flake outputs before advertising them;
- keep `nix run .#doctor` passing from a clean clone;
- add examples for the modules people can reasonably import;
- keep security posture explicit so publishing personal infrastructure does not
  look careless.

Distribution work:

- pin GitHub topics to discoverable terms such as `nixos`, `nix-flake`,
  `home-manager`, `sops-nix`, `impermanence`, `observability`, `tailscale`,
  `homelab`, and `dotfiles`;
- write one concise launch post showing the architecture, not a generic
  "dotfiles" announcement;
- submit only after reusable docs and clean-clone checks are green;
- answer issues by turning repeated questions into docs or tests;
- publish small follow-up posts per reusable module instead of one giant launch.

## Current Next Moves

1. Add import examples for `services-hardened` and `runtime-theme`.
2. Add a fake `examples/mini-fleet` only after the examples would validate.
3. Make `doctor` the main public entrypoint and ensure its output is friendly to
   someone who does not know the private fleet.
4. Keep host configs personal and documented as reference implementations rather
   than pretending they are copy-paste deploy targets.
