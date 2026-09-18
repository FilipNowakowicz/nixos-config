# Structural / Abstraction-Boundary Audit — 2026-09-18

Scope: read-only judgment audit of module/file/abstraction boundaries in
`/home/user/nix`, in both directions — under-abstracted (real duplication that
should be extracted but isn't) and over-abstracted (existing indirection that
isn't earning its keep). Builds on, and does not repeat, findings already
recorded in `audits/main-audit-2026-09-17.md`,
`audits/secrets-scoping-audit-2026-09-18.md`,
`audits/test-suite-depth-audit-2026-09-18.md`,
`audits/doc-module-drift-audit-2026-09-18.md`, and
`audits/ci-cd-audit-2026-09-18.md`.

Confidence labels: **Verified** (read the code / ran `nix eval`), **Plausible**
(strong textual evidence, not independently executed), **Speculative** (a
judgment call with weaker evidence).

---

## 0. The roadmap's own trigger, checked directly

`docs/goals/roadmap.md:51-58` ("Full Service Composition DSL"): a DSL emitting
Nginx locations, firewall rules, backup paths, hardening, and Alloy scrape
config "could be useful, but premature abstraction would hide important
security and exposure decisions." Trigger: "two or three additional services
repeat the same cross-cutting pattern and the manual edits become
error-prone."

To test this directly, every homeserver-gcp service's wiring across the five
axes was compared:

| Service     | nginx                                                                        | firewall                                                                                         | backup                                                                                   | `services.hardened.*`                   | Alloy/blackbox                                        |
| ----------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------- | --------------------------------------- | ----------------------------------------------------- |
| Vaultwarden | 2 `locations.*` under shared vhost (`nginx.nix:97-105`)                      | shared `tailscale0` 443 (`default.nix:97-100`)                                                   | sqlite `.backup` + exclude WAL/SHM (`backups.nix:132-147`)                               | **yes** (`default.nix:221-227`)         | `vaultwarden-root` probe (`default.nix:143-150`)      |
| Grafana     | 1 `locations."/grafana/"` + 2 auxiliary auth locations (`nginx.nix:107-147`) | shared `tailscale0` 443                                                                          | sqlite `.backup` + exclude WAL/SHM (`backups.nix:138,142-144`)                           | **no** (upstream module hardening only) | `grafana-auth-boundary` probe (`default.nix:157-160`) |
| AdGuard     | **separate `virtualHosts."adguard-ui"`**, not a location (`nginx.nix:70-87`) | **own** `networking.firewall.interfaces.tailscale0` block, ports 53/3001 (`adguard.nix:129-135`) | **rsync staging copy**, not sqlite; excludes `querylog.json` (`backups.nix:135-136,154`) | **no**                                  | **no probe**                                          |

Findings from the table: only two services (Vaultwarden, Grafana) share the
sqlite-backup-then-exclude shape, and that shared shape already lives as two
consecutive lines in **one** file (`backups.nix:138-139`), not duplicated
across per-service files — there is nothing here for a DSL to deduplicate.
AdGuard is a third "service" by service count, but its backup, firewall, and
proxy shape are all structurally different from the other two (DynamicUser
rsync staging vs. sqlite; dedicated vhost vs. shared-vhost location; its own
firewall ports vs. the shared 443). `services.hardened.*` is applied to
infrastructure (`nginx`, `tailscale-cert`) and to exactly one app service
(`vaultwarden`), not to Grafana or AdGuard, because those two already run
under DynamicUser + upstream-module hardening and don't need the baseline.

**Verified.** The roadmap's own trigger — "two or three additional services
repeat the same cross-cutting pattern" — has **not** been met. What looks at a
glance like "3 services, so pattern" is, on inspection, 3 services with 3
different exposure/backup/hardening shapes for genuine reasons (data
consistency model, DynamicUser vs. static user, dedicated vs. shared vhost).
This is exactly the situation the roadmap entry anticipated and told itself
not to abstract prematurely; that caution is currently correct. Next: no
action. Re-open only if a fourth service repeats the _exact_ Vaultwarden/
Grafana bundle (sqlite-backup-and-exclude + shared-vhost location + a
`blackbox` probe) a third time with no material difference.

---

## Direction A — Under-abstracted / extraction candidates

### A1. `lib/generators.nix`'s `systemd.timer` helper exists but 3 of 5 matching call sites bypass it

`lib/generators.nix:112-130` defines a small helper specifically for this
shape (`OnCalendar`/`Persistent`/optional `RandomizedDelaySec`/`wantedBy`) and
it is already adopted twice, verbatim, in the same host:

```nix
# hosts/homeserver-gcp/tailscale-cert.nix:44-47
timers.tailscale-cert = timer {
  schedule = "daily";
  jitter = "1h";
};
```

```nix
# hosts/homeserver-gcp/audits.nix:71-74
lynis-audit = timer {
  schedule = "daily";
  jitter = "1h";
};
```

But three more timers in the _same host_, matching the helper's shape
exactly (`OnCalendar` + `Persistent = true` + `RandomizedDelaySec`), are
hand-rolled instead:

```nix
# hosts/homeserver-gcp/backups.nix:97-104
restic-check-b2 = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "weekly";
    RandomizedDelaySec = "2h";
    Persistent = true;
  };
};
```

```nix
# hosts/homeserver-gcp/backups.nix:106-113
restic-restore-canary-b2 = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "04:30";
    Persistent = true;
    RandomizedDelaySec = "30m";
  };
};
```

```nix
# hosts/homeserver-gcp/restore-drill.nix:234-243
timers.restore-drill-b2 = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "*-01,04,07,10-01 05:30:00";
    Persistent = true;
    RandomizedDelaySec = "1h";
  };
};
```

Each of these three is a one-line substitution away from `timer { schedule =
"..."; jitter = "..."; }` — no new abstraction needed, the abstraction already
exists in the repo and two neighboring files already use it. (`heartbeat.nix`
timer at `heartbeat.nix:49-58` is correctly _not_ included — it uses
`OnBootSec`/`OnUnitActiveSec`, a genuinely different shape the helper doesn't
cover.)

**Verified.** Confidence high; the mechanical fix is trivial and low-risk.
Next: convert the three timers above to use `gen.systemd.timer`/`timer` for
consistency; not urgent (no behavior changes), but cheap and removes a
"why does this one file not use the helper" question for the next reader.

### A2. `sops.secrets.user_password.neededForUsers` + `hashedPasswordFile` wiring — real but below the extraction bar

`main`, `mac`, and `homeserver-gcp` each declare byte-identical:

```nix
# hosts/main/default.nix:603, hosts/mac/default.nix:288, hosts/homeserver-gcp/default.nix:246
user_password.neededForUsers = true;
```

and

```nix
# hosts/main/default.nix:627, hosts/mac/default.nix:314, hosts/homeserver-gcp/default.nix:310
hashedPasswordFile = config.sops.secrets.user_password.path;
```

`modules/nixos/profiles/sops-base.nix` already exists as exactly the shared
home for this ("shared base — all hosts set defaultSopsFile and declare
secrets", `sops-base.nix:8`), and it is imported by all 5 hosts, including the
2 that intentionally omit this block (`gcp-builder`, `gcp-agent` — both
explicitly documented as "Key-only login. No sops ... no console/recovery
password", `gcp-builder/default.nix:198`, `gcp-agent/default.nix:308`). Moving
this into `sops-base.nix` behind a small option (or just unconditionally,
since `sops.secrets.*` entries are inert unless referenced) is technically
straightforward and the natural home for it already exists.

**Verified**, but this is a genuine 2-line×3-host repeat, not the kind of
error-prone drift the roadmap-style trigger is meant to catch — the two
non-adopters have a real, already-documented reason to differ, and the win is
marginal (6 lines total). **Next:** low priority; fold into `sops-base.nix`
only if it's next being touched for another reason, not worth a standalone
change.

---

## Direction B — Over-abstracted / unearned complexity

### B1. `home/theme/module.nix`'s `themeDir`/`activeFile` generality has exactly one real consumer

`home/theme/module.nix:224-234` makes the theme _directory itself_
user-overridable: "Point this at your own directory to supply a different set
of themes without forking the module." This is real code — `themesDir`,
`makoTemplate`, and `allThemes` are all derived from the injected `themeDir`
rather than hardcoded — and it is the kind of generality that public-adoption
framing invites (`docs/public-adoption.md` lists `homeModules.runtime-theme`
as a shipped reusable module).

But across the whole repo, `themeDir` is only ever left at its default
(`./.  `, i.e. `home/theme`) or set to that exact same path a second time in
the test harness:

```
tests/home/theme-module.nix:11:  themeDir = ../../home/theme;
tests/home/theme-module.nix:46:      themeDir = ../../home/theme;
```

The only real invocation is `home/users/user/home.nix:323`
(`../../theme/module.nix`, no `themeDir` override). No host, no example, and
no second theme set anywhere in the repo actually exercises a different
`themeDir`. The 8 real themes under `home/theme/themes/` are genuinely used
(auto-discovered via `builtins.readDir`, not hardcoded), so the module's _own_
complexity is earned — the part that is not earned is the
"bring-your-own-theme-directory" indirection layered on top for a stranger who
does not yet exist as a consumer.

**Plausible** (confirmed zero non-default call sites by grep; the judgment
that this specific slice is "not earning its keep" rather than "cheap enough
not to matter" is a closer call — the added surface is genuinely small: two
options with defaults). **Next:** no urgent action; if/when a second theme
set or a second consumer of `homeModules.runtime-theme` actually appears,
keep the option — until then it's fine to leave as documented, low-cost
optionality rather than something to actively simplify.

### B2. `lib/hosts.nix`'s `homeManager.profiles` list + `homeManagerProfileModules` map is generality for a single always-identical value

`lib/host-registry.nix:27-29` declares `knownHomeManagerProfiles = [
"desktop" ]` — a closed enum with **exactly one legal value**, ever, fleet-wide.
`flake/hosts.nix:22-24` backs it with a name-keyed module map that also has
exactly one entry:

```nix
# flake/hosts.nix:22-24
homeManagerProfileModules = {
  desktop = ../home/profiles/desktop.nix;
};
```

and `flake/hosts.nix:43` composes it generically as a list-of-profiles:

```nix
++ map (profile: homeManagerProfileModules.${profile}) (hm.profiles or [ ])
```

In the registry itself, the field is set identically on the only two hosts
that use it:

```nix
# lib/hosts.nix:39-42 (main)
homeManager = {
  role = "desktop";
  profiles = [ "desktop" ];
  ...
```

```nix
# lib/hosts.nix:155-158 (mac)
homeManager = {
  role = "desktop";
  profiles = [ "desktop" ];
  ...
```

So the machinery supports _n_ named, independently composable home-manager
profile modules layered onto a role, validated against a closed vocabulary —
but in practice there is one profile, applied identically everywhere it's
used, and it is fully implied by `role == "desktop"` (a boolean would say the
same thing with one field instead of three: a registry list, a schema enum,
and a name-keyed module map). This is a clean instance of the pattern the
audit brief asked about: generality that would make sense with 2-3 real
profile modules, built ahead of there being more than one.

Contrast with `homeManager.packs` right next to it in the same hosts
(`lib/hosts.nix:43-48` vs. `:159-162`), which **is** earning its keep: `main`
enables all four known packs (`browsing`, `coding`, `latex`, `learning`) and
`mac` enables a genuinely different subset (`browsing`, `coding` only,
because of the 128 GB SSD constraint noted in `lib/hosts.nix:150-151`) — real,
host-differentiated variation through the same kind of list+registry
mechanism. `profiles` and `packs` sit right next to each other with the same
shape; only one of them is doing real work today.

**Verified** (grepped every use of `homeManager.profiles`/
`homeManagerProfiles`; confirmed via `nix eval` that `main`'s value is
literally `[ "desktop" ]`). **Next:** no urgent fix — the cost today is one
list field, one enum-of-one, and one map entry, all correctly documented. If
a second home-manager profile module never materializes, collapsing this into
`homeManager.role == "desktop" -> import desktop.nix` directly would remove
three moving parts for zero loss of behavior; do it opportunistically next
time `flake/hosts.nix` is touched, not as a standalone change.

---

## Checked and fine

- **`modules/nixos/services/hardened.nix` (`services.hardened.<name>` DSL).**
  7 real call sites across 2 hosts (`main`: `thermald`, `power-profiles-daemon`,
  `fwupd`, `bluetooth`; `homeserver-gcp`: `nginx`, `vaultwarden`,
  `tailscale-cert`), each with a materially different `relaxBase`/`extraConfig`
  combination driven by a documented per-service reason (e.g. `fwupd` needs
  `CAP_DAC_OVERRIDE`/`CAP_CHOWN`/`CAP_FOWNER` for its 2.1.4
  `fwupd-refresh` split-user layout, `bluetooth` needs
  `AF_BLUETOOTH`+`AF_NETLINK`). The `mkForce`-vs-`mkDefault` split
  (`hardened.nix:38-56`) is exercised by real upstream-unit collisions
  (`power-profiles-daemon`'s own tighter filter). The one genuinely unexercised
  option is `enable` (always left at its `default = true`, never set to
  `false` anywhere) — but that's a single boolean escape hatch, not worth
  flagging as a cost.
- **`lib/dashboards.nix` (Grafana panel/dashboard builder DSL).** Heavily used
  by `modules/nixos/profiles/observability/dashboards.nix` (35+ call sites for
  `timeseriesPanel`/`statPanel`/`tablePanel`/`gridPos`/`target`) and a second
  real consumer (`hosts/homeserver-gcp/dashboards.nix`). Earning its keep.
- **`lib/generators.nix`'s `toAlloyHCL`/`nestedBlock`/`ref`.** One consumer
  (`modules/nixos/profiles/observability/collectors.nix`), but that consumer
  builds a genuinely dynamic Alloy pipeline (per-host audit sources via
  `lib.mapAttrsToList`, conditional basic-auth blocks) that would be painful
  to hand-write as HCL strings. The abstraction earns its keep even with one
  call site because the _shape_ it generates varies per host, not because
  many files import it.
- **`lib/generators.nix`'s `nginx.proxyLocation`.** Also one call-site file
  (`hosts/homeserver-gcp/nginx.nix`), but used ~7 times inside that file
  across genuinely repeated proxy-location boilerplate
  (`target`/`websockets`/`basicAuthFile`/`extraConfig`). Right-sized: the
  generator's own comment (`generators.nix:105-106`) correctly warns future
  authors not to expand it into a routing DSL, and nothing here has.
  Refactoring this into a "1 file = don't abstract" rule would be wrong; the
  question is real internal repetition, which this has.
- **`modules/nixos/profiles/backup.nix` + `lib/backup-policy.nix`.** The
  cross-cutting piece that genuinely is shared fleet-wide (retention/
  `pruneOpts`, the daily timer) is already centralized in one profile + one
  pure-data file, referenced by both the module and the
  `homeserverGcpB2BackupUsesCriticalPolicy` invariant in `flake/checks.nix` so
  they can't independently drift. The host-specific pieces that remain
  per-host (`paths`, `backupPrepareCommand`, `exclude`) are host-specific for
  real reasons (different data, different consistency requirements) and are
  correctly _not_ forced into a shared shape — a good example of the roadmap's
  own caution being applied correctly today, not just stated as a future
  principle.
- **AdGuard's own `networking.firewall.interfaces.tailscale0` block
  (`adguard.nix:129-135`) alongside the fleet's shared 443/22 block in
  `default.nix:97-100`.** These are NixOS attribute-set merges on the same
  option, not duplication — AdGuard genuinely needs two extra ports (53, 3001)
  that no other homeserver-gcp service needs, and declaring them next to the
  service that needs them (rather than centralizing every port list in
  `default.nix`) keeps the "why is this port open" question answerable from
  one file.

---

## Summary

- **Direction A (under-abstracted):** 2 findings — both real but modest
  (A1: 3 unused call sites for an existing, already-adopted timer helper;
  A2: a 6-line, 3-host `sops`/password repeat with a documented reason two
  other hosts don't share it). Neither is the "3+ services, error-prone
  manual edits" shape the roadmap's DSL trigger describes.
- **Direction B (over-abstracted):** 2 findings — both real but low-cost
  (B1: theme-directory override with one real consumer; B2: a
  list+enum+module-map for a home-manager "profile" concept that only ever
  takes one value, sitting next to a `packs` mechanism with the same shape
  that _is_ earning its keep).
- **Roadmap DSL trigger:** **not met.** Direct side-by-side comparison of
  Vaultwarden/Grafana/AdGuard's nginx/firewall/backup/hardening/observability
  wiring (§0) shows 3 services with 3 structurally different shapes for
  documented reasons, not repeated boilerplate.
