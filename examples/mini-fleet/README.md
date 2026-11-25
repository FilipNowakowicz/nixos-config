# mini-fleet — a fake two-host example

This is a **teaching example, not a deploy target**. It shows the layering
pattern this flake uses for its real (personal) hosts under `hosts/` —
without exposing any of that personal fleet's identifiers.

> [!WARNING]
> Everything here is fake: the hostnames, the disk references, the
> observability endpoint, and the `ingestAuth` placeholder values. Do not try
> to deploy it as-is — copy the _pattern_, not the literal files. Real disk
> identifiers, tailnet hostnames, and secrets must come from your own
> infrastructure, never from an example.

## What it shows

`flake.nix` assembles two `nixosConfigurations`, **each importing only public
flake outputs** (`nixosModules.*` / `homeModules.*` — the same outputs
documented in [`docs/modules/services-hardened.md`](../../docs/modules/services-hardened.md)
and [`docs/theme.md`](../../docs/theme.md)). Neither host imports anything
under `hosts/` — that tree is this repo's personal reference implementation,
not a public contract.

| Host                  | Shape            | Layers (public `nixosModules.*` / `homeModules.*`)                                         |
| --------------------- | ---------------- | ------------------------------------------------------------------------------------------ |
| `workstation-example` | workstation-like | `profiles-desktop`, `profiles-security`, plus `homeModules.profiles-base` via Home Manager |
| `server-example`      | server-like      | `services-hardened`, `profiles-security`, `observability-client`                           |

The split mirrors the real fleet's shape: a desktop machine layers a UI
profile and a Home Manager user config on top of a shared security baseline; a
headless service host layers process confinement and remote telemetry instead
— with each host's `default.nix` carrying only host-local facts (identity,
disks, the one service it runs), exactly the boundary the layering pattern
relies on.

## Why it's fake

A copyable example is only honest if it cannot leak anything real:

- **No real hostnames** — `workstation-example` / `server-example` instead of
  this fleet's actual machine names.
- **No real disk IDs** — `fileSystems."/"` points at a `by-label` placeholder,
  never a `/dev/disk/by-id/*` path (those are unique per physical disk and
  would otherwise tie this example to real hardware).
- **No decryptable secrets** — the observability `ingestAuth` values are the
  same `"test-password"` placeholder used throughout `flake/checks.nix`'s
  fixtures; short and obviously fake, never a real credential.
- **No cloud project IDs or live tailnet hosts** — the remote endpoint is
  `observability.example.ts.net`, an `.example.` placeholder.

The whole tree is covered by the `lib-scan-plaintext-secrets` check (see
`bash scripts/validate.sh light`), the same gate the real fleet runs under.

## Proving it doesn't rot

`mini-fleet-example-fixture` in `flake/checks.nix` calls this flake's own
`outputs` function, with `nixos-fleet` bound to the repository checkout and the
other inputs to the root flake's pins. It evaluates both system toplevels and
the demo user's Home Manager activation, and asserts what this page and the
host comments describe:

- the workstation runs the Hyprland desktop and the security baseline
  (fail2ban, nftables), and its Home Manager user gets the base CLI set;
- the server confines `demo-app` with no capabilities and a private `/tmp`;
- the server ships telemetry only: a local Prometheus remote-writes to the
  placeholder endpoint and Alloy ships logs, while Grafana and Loki stay off;
- `inputs.nixos-fleet.url` still points at this repository.

A breaking change to any layered module therefore fails CI here before it
could reach a real host. `bash scripts/validate.sh light` runs it.

## Adapting the pattern for real use

1. Replace the fake `networking.hostName` with your own.
2. Point `fileSystems` at your own disko/hardware-configuration — never copy
   a `by-id` path from someone else's example or repo.
3. Swap the placeholder `remoteEndpoint`/`ingestAuth` for your own
   observability stack and `sops`-managed secrets (see
   [`docs/security.md`](../../docs/security.md)).
4. Pick the public `nixosModules.*` / `homeModules.*` layers that match your
   host's shape — see each module's doc for its option boundary and non-goals.
