# Host Registry And Inventory Export

`lib/hosts.nix` is the source of truth for fleet metadata. Host modules,
deploy-rs nodes, Tailscale ACL generation, backup policy, dashboards, and the
inventory export should consume this registry instead of duplicating host
facts.

The reusable boundary is intentionally small:

- `lib/host-registry.nix` exposes schema constants plus `validateHost` and
  `validateRegistry`.
- `lib/hosts.nix` contains this repo's concrete host data and validates it with
  the helper.
- `packages.inventory-data` builds `inventory.json`, which the host drift check
  (`scripts/check-host-drift.sh`) reads.
- `apps.inventory-json` prints the generated JSON to stdout.

## Registry Schema

Every host entry must define:

| Field    | Type   | Meaning                                      |
| -------- | ------ | -------------------------------------------- |
| `system` | string | Nix platform string such as `x86_64-linux`.  |
| `status` | enum   | `active`, `inactive`, or `legacy-supported`. |

Optional fields:

| Field         | Shape                                                      | Stable contract |
| ------------- | ---------------------------------------------------------- | --------------- |
| `deploy`      | `{ sshUser = string; }`                                    | Yes             |
| `tailnetFQDN` | string                                                     | Yes             |
| `tailscale`   | `{ tag = string; acceptFrom.<sourceTag> = [ port ... ]; }` | Yes             |
| `homeManager` | repo role/profile/pack metadata                            | Repo-local      |
| `backup`      | `{ class = "critical" or "standard"; name = string; }`     | Yes             |
| `dnsServer`   | bool; exactly one active host sets it                      | Repo-local      |
| `hardware`    | host-local identifiers such as `diskById`                  | Repo-local      |

`backup` also takes optional `restoreTest` and `restoreDrill` bools, which
declare that the host stamps restore-canary and restore-drill timestamps
(`lib/backup-evidence.nix`); `BackupEvidenceMissing` expects them. `dnsServer`
marks the host whose AdGuard Home is the tailnet DNS nameserver;
`validateRegistry` rejects a registry with zero or several active ones.

Example:

```nix
{
  homeserver = {
    system = "x86_64-linux";
    status = "active";
    deploy.sshUser = "user";
    tailnetFQDN = "homeserver.example.ts.net";
    tailscale = {
      tag = "server";
      acceptFrom.workstation = [
        22
        443
      ];
    };
    backup = {
      class = "critical";
      name = "b2";
    };
  };
}
```

## Inventory JSON

Build the package:

```sh
nix build '.#inventory-data'
jq . result/inventory.json
```

Print JSON directly:

```sh
nix run '.#inventory-json'
```

The top-level JSON has:

- `schemaVersion`: currently `1`.
- `repository`: source repository URL.
- `inventoryContract`: lists stable fields and repo-local fields.
- `hosts`: one object per exported host.

Stable host fields are:

- `name`
- `system`
- `status`
- `deployable`
- `deployUser`
- `backupClass`
- `homeManagerRole`
- `tailscaleTracked`
- `drift`

A host declares the facts the generator cannot derive through the
`profiles.drift` NixOS option (`modules/nixos/profiles/drift.nix`):
`trackedServices` and `drift.expectedExtraTCPPorts`. A host that publishes its
own `/etc/host-drift-inventory.json`, as `homeserver-gcp` does, reads the same
option and `lib/drift.nix`, so the two copies cannot disagree.

Repo-local host fields are also exported, but consumers should treat them as
allowed to evolve:

- `closurePath`
- `health`
- `impermanence`
- `openTCPPorts`
- `openUDPPorts`
- `resticBackups`
- `services`
- `stateVersion`
- `tailscaleTCPPorts`
- `tailscaleUDPPorts`
- `trackedServices`

Minimal example:

```json
{
  "schemaVersion": 1,
  "repository": "https://github.com/FilipNowakowicz/nixos-config",
  "hosts": [
    {
      "name": "homeserver",
      "system": "x86_64-linux",
      "status": "active",
      "deployable": true,
      "deployUser": "user",
      "backupClass": "critical",
      "homeManagerRole": null,
      "tailscaleTracked": true,
      "drift": {
        "tailscaleTag": "server",
        "tailnetFQDN": "homeserver.example.ts.net",
        "tcpPorts": [22, 443],
        "strictTCPPortSet": true,
        "systemdUnits": ["sshd.service", "tailscaled.service"]
      }
    }
  ]
}
```

A larger, sanitized snippet of real generated output — one full host entry with
`drift` and `health` populated, store-path hashes and the tailnet suffix
replaced with placeholders — is committed at
[`docs/samples/inventory.sample.json`](samples/inventory.sample.json). See
[`docs/public-adoption.md`](public-adoption.md#sample-artifacts) for how it is
generated and kept reproducible.
