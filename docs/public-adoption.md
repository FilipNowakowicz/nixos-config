# Public Adoption Plan

Goal: make this repository useful enough that strangers can learn from it,
reuse parts of it, and share it as a serious example of production-style NixOS
personal infrastructure.

Stars are an outcome, not an engineering requirement. The repository can earn
attention only if the public surface is easy to understand, safe to inspect, and
credible from a clean clone.

---

## Status (2026-06-25)

The reusable surface is largely shipped. Tracks 1–4 below are done unless noted:

- **Track 1 (modules):** promoted as flake outputs with docs and fixture tests —
  `nixosModules.services-hardened`, `observability-stack`, `observability-client`,
  `profiles-base`/`-desktop`/`-security`; `homeModules.runtime-theme`, `neovim`,
  `profiles-base`/`-desktop`, `profiles-workflow-packs`.
- **Track 1 (lib):** the three #127 "promote" candidates are done —
  `lib/dashboards.nix` and `lib/generators.nix` are now the `flake.lib.dashboards`
  / `flake.lib.generators` outputs with clean-clone boundary tests
  (`lib-dashboards`, `lib-generators`) and a public doc
  ([`docs/modules/lib-helpers.md`](modules/lib-helpers.md));
  `home/profiles/desktop-runtime.nix` is documented as the `runtime-theme`
  "what to theme" contract and pinned by the `theme-module` check.
  `lib/acl.nix` (the Tailscale ACL generator behind `nix run .#tailscale-acl`)
  was promoted the same way — `flake.lib.acl`, covered by the existing `lib-acl`
  boundary test and documented alongside the other two helpers.
- **Track 2 (clean clone):** `nix run .#doctor` exists (golden-tested via
  `lib-doctor`), alongside `inventory-json` / `tailscale-acl` apps and committed
  sanitized samples under `docs/samples/`.
- **Track 3 (example fleet):** [`examples/mini-fleet`](../examples/mini-fleet)
  exists (workstation + server hosts) importing only flake outputs, with the
  `lib-mini-fleet-flake` static check and `mini-fleet-example-fixture`.
- **Track 4 (artifacts) + README:** the front page leads with the reusable-module
  table, a "what to copy first" section, and `nix run .#doctor`.

Remaining is distribution work (launch post, GitHub topics) and ongoing "keep it
green from a clean clone" maintenance, not new extraction engineering.

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

nix fmt  # treefmt reformats the generated JSON to the repo's canonical style
```

The `jq` filter matches store-hash and tailnet-suffix _patterns_, not this
fleet's specific values, so running it again — here or against a fork with
different real identifiers — produces the same sanitized shape. The trailing
`nix fmt` keeps the committed JSON identical to what `nix fmt -- --fail-on-change`
expects in CI. Both commands are checked by `lib-scan-plaintext-secrets`
(`bash scripts/validate.sh light`), which scans every tracked file for
credential-shaped strings.

## Extraction Candidate Survey (#127)

A read-only discovery pass across `hosts/`, `modules/`, `lib/`, `home/`, and
`packages/` for logic that is currently fused to the personal fleet but could
become its own reusable flake output. This is a survey, not an extraction —
approved "promote" candidates return as their own scoped issues that plug into
the Track 1–4 work above, per the #127 acceptance criteria.

### Promote candidates

1. **`lib/dashboards.nix`** — Grafana dashboard builder helpers (`gridPos`,
   `mkDashboard`, datasource constants). What it does: turns small attrsets
   into typed Grafana JSON panels/dashboards. Coupling: none — pure functions
   over `lib`, with no host, hostname, or identifier references; only consumed
   today by `modules/nixos/profiles/observability/dashboards.nix`.
   Recommendation: **promote** as `lib.dashboards` (or
   `nixosModules.observability-stack` could re-export it as
   `config.lib.observability.dashboards`) so people building their own Grafana
   provisioning can reuse the builders without adopting the whole stack.
   Boundary test: a `nix eval` fixture that imports `lib/dashboards.nix`
   directly (no `lib`, `pkgs`, or `hostRegistry` args beyond stock `nixpkgs.lib`)
   and asserts the JSON shape of a sample `mkDashboard` call — proves it
   evaluates with zero fleet context.

2. **`lib/generators.nix`** — generic Nix-attrset-to-config-format serializers
   (`toAlloyHCL`, `nginx.proxyLocation`, `systemd.timer`). What it does:
   converts typed Nix values into Alloy/River HCL text and common
   nginx/systemd option shapes. Coupling: none — takes only `{ lib }`; no
   private values appear anywhere in the file. Recommendation: **promote** as
   `lib.generators`, documented as a small standalone config-DSL helper library
   useful to anyone writing Alloy configs or repetitive nginx/systemd module
   glue. Boundary test: `nix eval --expr` against the bare file with stock
   `nixpkgs.lib`, checking `toAlloyHCL` output text for a two-component sample
   and `nginx.proxyLocation` attrset shape.

3. **`home/profiles/desktop-runtime.nix`** — the single shared list of
   theme-reloaded Wayland UI packages (`kitty`, `waybar`, `swaybg`) consumed by
   both `home/profiles/desktop.nix` and `home/theme/module.nix` so the install
   list and the theme-switch runtime inputs cannot drift. What it does: a tiny
   `{ pkgs }: [ ... ]` package list with a documented anti-drift contract.
   Coupling: none — no hostnames, paths, or identifiers; pure package list.
   Recommendation: **promote** alongside `homeModules.runtime-theme` as part of
   its public contract (either inlined in its docs as the canonical "what to
   theme" list, or exported as a small `homeModules.runtime-theme-runtime`
   helper) so adopters of `runtime-theme` know which packages the theme module
   expects to reload. Boundary test: extend the existing
   `tests/home/theme-module.nix` fixture (or a new minimal one) to assert the
   theme module's `themeSwitch` runtime inputs include exactly the packages
   from this list — proving the no-drift contract holds outside the full
   desktop profile.

### Keep-as-reference candidates

4. **`packages/control-center`** — a GTK4/Wayland system control panel
   (network, bluetooth, power, theme, Tailscale/Mullvad toggles) already built
   as a flake-buildable package (`nix build .#control-center`) with its own
   `README.md`. What it does: a polished, real piece of UI infra. Coupling:
   moderate — it is general-purpose GTK4 Wayland code, but its feature set
   (Mullvad + Tailscale coexistence, specific hyprland/waybar integration
   assumptions) is shaped around this fleet's desktop stack and is already
   documented as personal-reference UI rather than a generic applet.
   Recommendation: **keep as reference** — it already has a flake output and
   docs; the missing piece for "promote" status (a clean-clone boundary test
   that builds it without `hosts/` and a documented option surface for
   reusing only parts of it) is a larger UI-extraction effort than this issue's
   discovery scope, and the control panel's value is as a real-UI showcase
   (Track 4), not as an importable module.

5. **`home/files/scripts/{launcher.py,waybar-anchor.py,theme-switch.sh,
waybar-weather.sh,hypr-display-mode.sh,waybar-toggle.sh,clipboard-pick.sh}`**
   — the Hyprland/Waybar runtime helper scripts wired through
   `home/users/user/home.nix`. What they do: a pill-style app launcher,
   waybar status helpers, the theme-switch runtime driver, and small
   Hyprland display/clipboard utilities. Coupling: low on private identifiers
   (no hostnames/keys), but each is hand-tuned to this fleet's specific
   monitor names (`DVI-I-1`/`eDP-1`), color/theme file layout, and waybar
   module wiring — extracting them as standalone packages would require
   generalizing those assumptions into options. Recommendation: **keep as
   reference** — genuinely useful as copy-and-adapt examples for a Hyprland
   desktop (and the README/theme docs already frame them that way), but
   promoting them to `packages.*` would mean inventing a generic
   Hyprland-desktop option surface this repo does not need and the issue's
   non-goals warn against ("do not turn `hosts/` into a generic distribution").

6. **`modules/nixos/profiles/{backup,security,sops-base,machine-common,
impermanence-base,user}.nix`** — the shared host baseline profiles
   (restic backup-class scheduling, firewall/coredump/fail2ban hardening,
   sops bootstrap + SSH-key `authorizedKeys`, SSH defaults, btrfs
   rollback-on-boot, primary-user account). What they do: form the
   `services-hardened`-adjacent baseline every host imports. Coupling: real —
   `backup.nix` keys off `hostMeta.backup` from the private host registry,
   `sops-base.nix` imports `lib/pubkeys.nix` (a real public key) and assumes
   sops/age bootstrap, `user.nix`/`impermanence-base.nix` assume this fleet's
   specific account, btrfs subvolume layout (`@root`/`@root-blank`), and
   persistence directories. Recommendation: **keep as reference** — these
   patterns (class-based backup pruning, sops bootstrap shape, impermanence
   rollback) are exactly the kind of thing `docs/architecture.md` already
   explains conceptually; turning them into standalone outputs would require
   inventing a generic identity/disk/backup-target option surface, which is
   explicitly out of scope ("do not turn `hosts/` into a generic
   distribution"). `services-hardened` (already promoted) is the right home
   for any hardening pattern that does generalize cleanly.

7. **`hosts/gcp-builder`** — the on-demand remote-Nix-builder host shape
   (disposable microVM-style box: broad passwordless sudo, trusted-user wiring,
   power-on/off automation referenced from `scripts/validate.sh`). What it
   does: documents a clean "ephemeral remote builder" pattern others could
   copy. Coupling: high — hostnames, Tailscale firewall scoping, GCP
   provisioning via `scripts/deploy-gcp.sh`/Terraform, and `lib/hosts.nix`
   registry entries are all fleet-specific. Recommendation: **keep as
   reference** — `hosts/gcp-builder/CLAUDE.md` already documents the
   provisioning runbook; that's the right level of reuse (a documented
   pattern to adapt) rather than a flake output, since a generic "remote
   builder module" would need to abstract away cloud provider, identity, and
   network specifics this repo intentionally keeps concrete.

### Reject candidates

8. **`lib/pubkeys.nix` / `lib/recovery-pubkeys.nix`** — three-line lists of
   this fleet's real SSH public keys, imported by `sops-base.nix`/`user.nix`.
   What they do: supply `authorizedKeys.keys`. Coupling: total — they _are_
   private identifiers (real `user@NixOS` / `recovery@main` keys).
   Recommendation: **reject** — these cannot be generalized; they are the
   textbook example of "private identifier", and any reusable module that
   needs authorized keys should take them as an option argument (which
   `modules/nixos/profiles/user.nix` effectively already could, if promoted —
   but the _data_ itself stays personal).

9. **`home/profiles/workflow-packs/*`** (`browsing`, `coding`, `latex`,
   `learning`) — small `lib.mkEnableOption`-gated package-list toggles
   (Chromium, VS Code, TeX Live, Anki) already exported as
   `homeModules.profiles-workflow-packs`. What they do: opt-in app bundles.
   Coupling: none beyond personal taste in app choice. Recommendation:
   **reject** as a _new_ candidate — it is already a named flake output
   (`homeModules.profiles-workflow-packs`); any further "promotion" work
   (docs, boundary test) belongs to Track 1, not to a new extraction issue.

### Summary

Of 9 candidates surveyed: **3 promote** (`lib/dashboards.nix`,
`lib/generators.nix`, `home/profiles/desktop-runtime.nix`), **4 keep as
reference** (`control-center`, the Hyprland/Waybar scripts, the shared host
baseline profiles, `gcp-builder`), and **2 reject** (the pubkey lists, and
`workflow-packs` as a _new_ candidate — it is already an existing output).

**Done (2026-06-25).** All three promote candidates landed:

- `lib/dashboards.nix` → `flake.lib.dashboards`, with the `lib-dashboards`
  clean-clone boundary test (imports the bare file with stock `nixpkgs.lib`).
- `lib/generators.nix` → `flake.lib.generators`, covered by the existing
  `lib-generators` / `lib-generators-structured` boundary tests.
- `home/profiles/desktop-runtime.nix` → documented as the `runtime-theme`
  "what to theme" contract, with the exact package list pinned by the
  `theme-module` check (`testRuntimeThemeContract`); both consumers import the
  one file, so the install list and switcher inputs cannot drift.

The two lib helpers share a public doc:
[`docs/modules/lib-helpers.md`](modules/lib-helpers.md).

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

The engineering moves from the original plan have landed (see
[Status](#status-2026-06-25)): import examples for the reusable modules,
`examples/mini-fleet`, and `doctor` as the public entrypoint all exist. What
remains is distribution and upkeep, not new module work:

1. Write one concise launch post showing the architecture (not a generic
   "dotfiles" announcement), and pin the discoverable GitHub topics listed under
   [Distribution work](#star-growth-checklist).
2. Keep `nix run .#doctor` and the clean-clone checks green from a fresh clone;
   turn repeated visitor questions into docs or tests rather than one-off replies.
3. Keep host configs personal and documented as reference implementations rather
   than pretending they are copy-paste deploy targets.
