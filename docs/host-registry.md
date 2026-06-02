# Host Registry And Inventory Export

`lib/hosts.nix` is the source of truth for fleet metadata. Host modules,
deploy-rs nodes, Tailscale ACL generation, backup policy, dashboards, and the
homepage inventory export should consume this registry instead of duplicating
host facts.

The reusable boundary is intentionally small:

- `lib/host-registry.nix` exposes schema constants plus `validateHost` and
  `validateRegistry`.
- `lib/hosts.nix` contains this repo's concrete host data and validates it with
  the helper.
- `packages.inventory-data` builds `inventory.json` for status/homepage
  consumers.
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
| `hardware`    | host-local identifiers such as `diskById`                  | Repo-local      |

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
- `homeManagerProfiles`
- `tailscaleTracked`
- `drift`

Repo-local host fields are still exported for this fleet's dashboard and
homepage, but consumers should treat them as allowed to evolve:

- `closurePath`
- `closureSizeBytes`
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

`closureSizeBytes` remains part of the export because the homepage consumes it.
It is nullable: a value of `null` means the evaluated system closure path was
not present in the local Nix store when `packages.inventory-data` was built.

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
      "homeManagerProfiles": [],
      "tailscaleTracked": true,
      "closureSizeBytes": 1234567890,
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
