# Tailscale ACL Generator

`lib/acl.nix` derives a Tailscale ACL policy from the same host registry
(`lib/hosts.nix`) that drives deploy, inventory, and backups. Generating the
policy from one source of truth keeps the tailnet from drifting away from host
configuration: a new node with a known tag automatically inherits the right
access without hand-editing `acl.hujson`.

This is an **opinionated generator for this repo's model**, not a general ACL
mini-library. It intentionally emits only `tagOwners` and `acls`, owns every tag
with `autogroup:admin`, and adds a single break-glass rule. It does not generate
`groups`, `ssh`, `autoApprovers`, or `nodeAttrs` — this fleet reaches SSH over
the tailnet through firewall rules, not Tailscale SSH.

The reusable boundary is small:

- `lib/acl.nix` exposes `mkAcl hostRegistry`.
- `packages.tailscale-acl` renders the policy to a JSON file.
- `apps.tailscale-acl` prints that JSON to stdout.
- `scripts/check-tailscale-acl-drift.sh` (wired into the
  `tailscale-acl-drift` workflow) diffs the rendered policy against the live
  tailnet.
- `scripts/apply-tailscale-acl.sh` fetches the full live policy, replaces only
  rendered `tagOwners` and `acls`, and POSTs the merged policy back with the
  live `ETag` guard.

## Required Host Metadata

`mkAcl` reads only the `tailscale` block of each host. Hosts without a
`tailscale` attribute are ignored.

| Field                  | Type               | Meaning                                                    |
| ---------------------- | ------------------ | ---------------------------------------------------------- |
| `tailscale.tag`        | string             | Tag carried by this host, without the `tag:` prefix.       |
| `tailscale.acceptFrom` | attrset (optional) | Map of `<sourceTag> = [ port ... ]` — inbound allow rules. |

`acceptFrom.<sourceTag>` means "tag `sourceTag` may reach this host's tag on the
listed ports". Ports are integers in `1–65535`. A port spec with no protocol
covers all protocols (TCP, UDP, ICMP) in Tailscale, matching the registry's
"TCP+UDP" intent.

Example:

```nix
{
  homeserver = {
    tailscale = {
      tag = "server";
      acceptFrom.workstation = [
        22
        443
      ];
    };
  };
  laptop = {
    tailscale.tag = "workstation";
  };
}
```

### Validation

Every `acceptFrom` source tag must be a tag that **some host actually carries**.
If a source tag is never owned (typo, or accepting from a class of node that
does not exist yet), `mkAcl` throws at evaluation:

```
lib/acl.nix: acceptFrom references undefined tag(s) ["workstaton"]; every
source tag must be carried by some tailnet host (defined tags: [...])
```

This fails fast instead of emitting a policy that references an undefined tag,
which the Tailscale API would reject only on the next live apply.

## Generated Policy Shape

`mkAcl` returns:

- `tagOwners`: `tag:<name> = [ "autogroup:admin" ]` for every tag in the fleet.
- `acls`: one `accept` rule per source tag (destinations grouped and sorted by
  `tag:dst:port`), followed by a single break-glass rule
  `autogroup:admin → *:*`.

Rules are tag-to-tag, so new nodes joining an existing tag inherit access
automatically. Tailscale ACLs are connection-oriented, so accepted inbound
flows do not need separate reverse rules for return traffic.

Serialize with `builtins.toJSON` to obtain `acl.hujson` content.

## Build And Inspect

Build the artifact:

```sh
nix build '.#tailscale-acl'
jq . result
```

Print the JSON directly:

```sh
nix run '.#tailscale-acl'
```

## Check For Drift

Compare the rendered policy against the live tailnet (only `tagOwners` and
`acls` are diffed, key-sorted, so formatting noise is ignored):

```sh
export TAILSCALE_API_KEY=tskey-api-...   # needs policy:read
export TAILSCALE_TAILNET=example.ts.net
bash scripts/check-tailscale-acl-drift.sh
```

The `tailscale-acl-drift` GitHub workflow runs this daily in detect-only mode.
Pushes to `main` that touch ACL inputs run the workflow in apply mode first,
then rerun the drift check.

## Apply The Generated Policy

Apply with the merge-safe helper, not a raw POST of the rendered artifact. The
rendered artifact contains only `tagOwners` and `acls`; the helper preserves
live-only sections such as `ssh`, `autoApprovers`, `nodeAttrs`, and `groups`.
The API key needs ACL read/write access.

```sh
bash scripts/apply-tailscale-acl.sh --dry-run
bash scripts/apply-tailscale-acl.sh
```
