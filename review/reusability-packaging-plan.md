# Reusability And Packaging Plan

This plan tracks a broad cleanup direction for the flake: keep the repository as
real personal infrastructure, but sharpen the boundaries around the parts that
are useful outside one machine. The goal is not to turn the repo into a generic
NixOS distribution. The goal is to make the reusable pieces have clear public
contracts, tests, docs, and flake outputs while host files stay personal and
hardware-bound.

## Guiding Idea

The repo should read as:

> A real NixOS fleet with extracted building blocks for hardening,
> observability, host inventory, ACL generation, validation, and selected
> desktop tooling.

That means:

- Move host-specific assumptions upward into `hosts/`.
- Keep reusable logic in `modules/`, `lib/`, `packages/`, and `templates/`.
- Expose reusable pieces through stable flake outputs.
- Add focused docs and examples for each public contract.
- Add small tests or fixtures that prove the reusable piece works without
  importing the full personal host configuration.

## Non-Goals

- Do not make `main`, `mac`, `homeserver-gcp`, or `gcp-builder` generic starter
  hosts.
- Do not hide that this is personal infrastructure.
- Do not rewrite working modules just to rename everything.
- Do not promote a module as reusable while it still depends implicitly on
  personal host names, secret names, tailnet paths, or hardware.
- Do not package random dotfiles unless they have a clear external contract.

## Candidate 1: `services.hardened`

Type: NixOS module.

Current location:

- `modules/nixos/services/hardened.nix`

Why this is useful:

- Many NixOS users want reusable systemd hardening defaults.
- The existing module already has a real option boundary:
  `enable`, `relaxBase`, and `extraConfig`.
- It solves a concrete problem without needing this repo's host topology.

Target shape:

- Expose as `nixosModules.services-hardened`.
- Add `docs/modules/services-hardened.md`.
- Include minimal examples for common services such as `nginx`, `vaultwarden`,
  and a generic custom service.
- Keep the current internal option name if changing it would create churn.
- Add or expand tests proving:
  - baseline settings are applied;
  - forced settings win unless listed in `relaxBase`;
  - `extraConfig` can override non-forced defaults;
  - null values are rejected.

Rewrite level: low. This is mainly polish and exposure.

## Candidate 2: Observability Stack

Type: NixOS modules and profile.

Current locations:

- `modules/nixos/profiles/observability/`
- `modules/nixos/profiles/observability-client.nix`
- `hosts/homeserver-gcp/grafana.nix`
- `hosts/homeserver-gcp/dashboards.nix`
- `lib/dashboards.nix`
- `lib/observability-alerts.nix`

Why this is useful:

- A declarative single-node LGTM stack is genuinely valuable for NixOS and
  homelab users.
- The repo already has Grafana, Mimir, Loki, Tempo, Alertmanager, blackbox
  probes, audit streams, dashboards, and alert rules wired together.
- This could become the strongest reusable project if it is separated cleanly
  from `homeserver-gcp`.

Target shape:

- Expose as `nixosModules.observability-stack`.
- Expose client shipping as `nixosModules.observability-client`.
- Document two modes:
  - local single-node stack;
  - remote client pushing to a central stack.
- Make host-specific routing, domains, labels, secret names, and ingress paths
  explicit options or host-level configuration.
- Keep dashboards and alert rules overridable.
- Add a minimal test fixture that enables the stack without importing
  `homeserver-gcp`.

Rewrite level: medium. The core should survive, but host-specific assumptions
need to be pushed out of the public module boundary.

## Candidate 3: Host Registry And Inventory Export

Type: pure library plus package/app output.

Current locations:

- `lib/hosts.nix`
- `packages/inventory-data.nix`
- `flake/hosts.nix`
- `flake/deploy.nix`

Why this is useful:

- NixOS fleet repos often drift because host metadata is duplicated across
  deploy config, dashboards, websites, ACLs, backups, and docs.
- This repo already treats `lib/hosts.nix` as the single source of truth.
- The inventory export is small, clean, and easy to explain.

Target shape:

- Keep `packages.inventory-data`.
- Add an app wrapper such as `apps.inventory-json` if that improves usability.
- Document the host metadata schema.
- Include example JSON output.
- Add tests for the public fields and failure behavior.
- Make clear which fields are stable public contract and which are repo-local.

Rewrite level: low.

## Candidate 4: Tailscale ACL Generator

Type: pure library plus package/app output.

Current locations:

- `lib/acl.nix`
- `flake/dev.nix` package output `tailscale-acl`
- `.github/workflows/tailscale-acl-drift.yml`
- `scripts/check-tailscale-acl-drift.sh`

Why this is useful:

- Tailnet policy often drifts from host configuration.
- Generating ACLs from the same host registry that drives deploy and inventory
  gives the repo a strong "single source of truth" story.
- The existing drift check makes this more than a static example.

Target shape:

- Keep `packages.tailscale-acl`.
- Add an app wrapper such as `apps.tailscale-acl`.
- Document the required host metadata fields.
- Include an example command for checking or applying the generated ACL.
- Add tests for common policy shapes and invalid metadata.
- Decide whether this is a general ACL mini-library or a documented opinionated
  generator for this repo's model.

Rewrite level: low to medium.

## Candidate 5: Packaged Control Center

Type: package/app, optionally paired with a Home Manager module.

Current locations:

- `packages/control-center/`
- `flake/dev.nix` package and app output `control-center`
- `home/users/user/home.nix`

Why this is useful:

- Hyprland and Wayland users often want a polished system control panel.
- The app is already packaged as a first-class flake package instead of a loose
  script.

Risks:

- It is narrower than the infrastructure modules.
- It likely assumes this repo's exact command set and desktop environment:
  GTK4 layer shell, NetworkManager, Bluetooth, Mullvad, Tailscale,
  brightnessctl, WirePlumber, Mako, and wlsunset.

Target shape:

- Add `packages/control-center/README.md`.
- Document runtime dependencies and assumptions.
- Add screenshot or short demo only as supporting material, not the main repo
  pitch.
- Make optional integrations degrade gracefully when a tool is absent.
- Consider a Home Manager module later if configuration becomes necessary.

Rewrite level: low for showcase, medium for broad external reuse.

## Candidate 6: Python Dev-Shell Template

Type: flake template.

Current location:

- `templates/python/flake.nix`

Why this is useful:

- It is easy to consume and test.
- It rounds out the repo's "developer workflow" story.

Risks:

- Python dev shells are common, so this should not be a headline feature.

Target shape:

- Keep as `templates.python`.
- Add a short usage example.
- Ensure it stays minimal and does not pull in personal assumptions.

Rewrite level: low.

## Candidate 7: Theme Runtime System

Type: Home Manager module and packageable helper scripts.

Current locations:

- `home/theme/`
- `home/files/scripts/theme-switch.sh`
- `home/files/waybar/`
- `home/files/hypr/`
- `home/files/kitty/`

Why this is useful:

- Runtime theme switching without a full rebuild is an attractive desktop
  pattern.
- The repo already has multiple themes, generated assets, and shell integration.

Risks:

- It is probably coupled to this exact Hyprland, Waybar, Mako, Kitty, and
  wallpaper setup.
- It should not distract from the infrastructure story unless the module
  boundary becomes clean.

Target shape:

- First clean it for this repo: remove duplicated runtime inputs and centralize
  theme defaults.
- Move shell interpolation toward Nix-generated templates where practical.
- Later decide whether to expose a `homeModules.runtime-theme` module.

Rewrite level: medium.

## Candidate 8: Restore Canary And Backup Validation Pattern

Type: docs, checks, and optional module helpers.

Current locations:

- `hosts/main/backups.nix`
- `hosts/homeserver-gcp/backups.nix`
- `docs/restore-drill.md`
- `flake/checks.nix`

Why this is useful:

- Many self-hosted systems have backups but no restore proof.
- This repo already has restore drills, backup coverage, and canary-style
  validation.

Target shape:

- Document the pattern clearly before trying to generalize it.
- Keep host-specific B2/restic paths in hosts.
- Consider small helper functions only if duplication becomes obvious.

Rewrite level: low for docs, medium if turned into reusable modules.

## Candidate 9: Remote Builder Pattern

Type: documentation, template, or narrowly reusable module.

Current locations:

- `hosts/gcp-builder/`
- `hosts/main/nix-remote-build.nix`
- `docs/operations.md`

Why this is useful:

- On-demand remote builders are useful for laptops/workstations.
- The repo has a real cloud builder lifecycle rather than a toy example.

Target shape:

- Keep as a documented pattern first.
- Avoid pretending the current GCP-specific host is a generic package.
- Extract helpers only if multiple cloud providers or multiple builders appear.

Rewrite level: low for docs, high if generalized too early.

## Suggested Implementation Order

1. `services.hardened`
   - smallest useful public contract;
   - validates the extraction style;
   - low risk to existing hosts.

2. Host registry, inventory export, and Tailscale ACL generator
   - strengthens the single-source-of-truth story;
   - improves repo cleanliness even if nobody else uses it;
   - keeps changes mostly in `lib/`, `packages/`, and docs.

3. Observability stack
   - highest public value;
   - needs the most careful option-boundary cleanup.

4. Control center
   - polish as a package/showcase;
   - do not make it the main pitch unless configuration and missing-tool
     behavior are cleaned up.

5. Theme runtime system, restore canary pattern, remote builder pattern
   - document first;
   - extract only after the boundaries become obvious.

## Definition Of Done For A Reusable Piece

A component is ready to promote in the README when it has:

- a named flake output;
- a short doc page or README section;
- a minimal example;
- a real repo example;
- a clean-clone validation path;
- tests or fixtures where practical;
- no hidden dependency on personal host names, secret names, hardware paths, or
  tailnet domains unless documented as an explicit input.

## README Impact

Once the first pieces are polished, the README should lead with the repo as a
real NixOS fleet that exposes reusable building blocks. The strongest headline
should be infrastructure patterns, not desktop screenshots:

- impermanence with persistence checks;
- systemd hardening DSL;
- declarative observability;
- host registry as source of truth;
- generated Tailscale ACLs and inventory;
- restore drills and validation.

UI screenshots can remain secondary proof of polish, especially for the control
center and Hyprland setup, but they should not define the project.
