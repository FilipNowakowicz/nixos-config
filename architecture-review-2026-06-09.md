# Architecture Review — 2026-06-09

Read-and-report verification of the implementation against the intended design
in `CLAUDE.md`, `README.md`, and `docs/architecture.md`. No source files were
changed. Every claim below was verified by reading the cited file or by an
eval experiment noted inline.

**Overall verdict:** the layering model is real, not aspirational — Layer 0
purity holds, option contracts in the observability/hardening modules are
genuinely well-typed, assertions are used where they matter, and the registry
drives the ACL, inventory, sops parity, and deploy-node generation as
documented. The significant gaps cluster in two places: (1) the public-adoption
module exports are not actually decoupled from the fleet (two of them break for
an adopter, and the CI fixture style cannot detect it), and (2) the registry's
single-source-of-truth claim stops at the host firewall and CI-plan boundary,
where the same facts are hand-maintained in parallel.

Legend: **[S]** structural issue · **[I]** inconsistency · **[F]** future-friction.

---

## Part 1 — Confirmed problems

### 1. [S] Public `profiles-base` cannot evaluate outside this fleet

- `modules/nixos/profiles/base.nix:11` does
  `inherit (config.lib.profiles.observability) mkPromScript;` (used at
  `base.nix:18`), but that helper is only defined inside
  `config = lib.mkIf cfg.enable { ... }` at
  `modules/nixos/profiles/observability/collectors.nix:609-611`. So the module
  exported as `nixosModules.profiles-base` (`flake.nix:246`) requires the
  observability module to be **imported and enabled**.
- **Verified empirically:** evaluating a minimal `nixosSystem` with only
  `profiles/base.nix` fails with an attribute-missing error at `base.nix:11`.
  It additionally requires `inputs` and `self` as specialArgs
  (`base.nix:10,35`), which no adopter flake provides under those names.
- The cost is already visible inside the fleet:
  `hosts/gcp-builder/default.nix:51-55` enables
  `profiles.observability.enable = true` _solely_ to satisfy `base.nix` — a
  host turning on a profile it explicitly does not want, to satisfy an
  undeclared cross-module dependency. This is exactly the "implicit coupling
  where one module silently depends on another being imported" failure mode,
  and it violates the public contract in `docs/public-adoption.md` ("no
  dependency on private … assemblies"; fixtures prove standalone use — there is
  no fixture for `profiles-base`).
- **Fix:** define `lib.profiles.observability` unconditionally (outside the
  `mkIf`), or better: make `mkPromScript` a pure `lib/` function taking `pkgs`,
  and move the `exportSystemMetadata` activation script out of `base.nix` into
  the observability module gated on its own `enable`. Make
  `system.configurationRevision` tolerate missing `self` (or document the
  required specialArgs in the export).

### 2. [S] Public `profiles-desktop` hardcodes the fleet username — the shipped mini-fleet example does not build

- `modules/nixos/profiles/desktop.nix:15` sets
  `users.users.user.extraGroups = [ "input" ]` in a module exported as
  `nixosModules.profiles-desktop` (`flake.nix:247`) and held up by
  `examples/mini-fleet/flake.nix:40` as the copyable pattern. The example's
  workstation defines its user as `demo`
  (`examples/mini-fleet/hosts/workstation-example/default.nix:18-21`), so the
  desktop profile conjures a phantom `user` account.
- **Verified empirically:** evaluating the workstation-example +
  `profiles-desktop` + `profiles-security` composition yields failed NixOS
  assertions:
  - `Exactly one of users.users.user.isSystemUser and users.users.user.isNormalUser must be set.`
  - `users.users.user.group is unset…`

  i.e. the published example cannot produce a bootable toplevel as shipped.

- **Why CI doesn't catch it:** `miniFleetExampleFixture`
  (`flake/checks.nix:514-556`) samples individual config values
  (`networking.hostName`, `programs.hyprland.enable`, …) instead of forcing the
  toplevel. Assertions are only checked when `system.build.toplevel` is forced.
  The repo already has the right pattern one screen up —
  `observabilityDashboardBackendAssertionFixture` deepSeqs
  `toplevel.drvPath` (`flake/checks.nix:417-456`) — it just isn't used for the
  adopter-facing fixtures.
- **Fix:** parameterize the user (e.g. a `profiles.desktop.user` option whose
  consumers are gated, or move the `input`-group grant to the host/user layer
  where `users.users.user` is actually defined — `modules/nixos/profiles/user.nix:3-11`),
  and make `miniFleetExampleFixture` force `toplevel.drvPath` via
  `builtins.deepSeq`/`tryEval` so adopter breakage fails `merge-gate`.

### 3. [I] `nixosConfigurations.homeserver-gcp` is a CI-stub variant, and the stub is dead machinery with a stale justification

- `flake.nix:220` exposes `ciNixosConfigs` as the flake's
  `nixosConfigurations`. `flake/hosts.nix:112-135` _replaces_
  `homeserver-gcp` there with a variant that does
  `disabledModules = [ "…/google-compute-config.nix" ]` plus stub
  `fileSystems."/"`/`grub.device`, justified by the comment that the module "is
  still active on real deployments via hardware-configuration.nix →
  google-compute-image.nix" (`flake/hosts.nix:117-121`).
- **That comment is no longer true.** `hosts/homeserver-gcp/hardware-configuration.nix:3-5`
  imports only `installer/scan/not-detected.nix`; a repo-wide grep finds no
  other reference to `google-compute-*`. The disabledModules entry disables a
  module nobody imports, and the stubs are inert `mkDefault`s under disko.
- The structural problem is the split it creates: deploy-rs nodes are built
  from `allNixosConfigs` (`flake.nix:223` → `flake/deploy.nix:31,35`), while
  the documented manual-closure-deploy fallback
  (`CLAUDE.md` Deploy Commands; `hosts/homeserver-gcp/CLAUDE.md` Ongoing
  Updates) builds `.#nixosConfigurations.homeserver-gcp` — the stubbed variant.
  Today the two almost certainly converge to the same closure, but the repo now
  maintains two definitions of one deployed host, and any future
  `extraModules` addition to the CI variant silently changes what manual
  deploys ship versus what deploy-rs ships.
- **Fix:** delete the `homeserver-gcp` override from `ciNixosConfigs` entirely
  (keeping only `main-ci`). If a future GCE-image module reintroduces the
  eval-time `readFile` problem, gate it behind `profiles.ci` like everything
  else rather than maintaining a parallel host definition.

### 4. [S] Registry `acceptFrom` drives the Tailscale ACL but not the host firewalls — no parity check, and drift already exists

- The design (`docs/architecture.md` Rule 3, `lib/hosts.nix:10-11`) makes
  `tailscale.acceptFrom` the source for the generated ACL
  (`lib/acl.nix:53-97`). But the _host-side_ enforcement of the same boundary —
  `networking.firewall.interfaces.tailscale0.allowed{TCP,UDP}Ports` — is
  hand-maintained per host with no derivation and no parity invariant:
  `hosts/main/networking.nix:60-75`, `hosts/mac/default.nix:43-51`,
  `hosts/gcp-builder/default.nix:31`, `hosts/homeserver-gcp/default.nix:109-113`.
  The invariants only pin hardcoded subsets (`22`/`443`) per host
  (`lib/invariants.nix:489-520`), which is a _third_ hand-copy of the same
  facts.
- **Drift exists today:** `mac` opens UDP 21027 on tailscale0
  (`hosts/mac/default.nix:49-51`) but its registry entry allows only
  `[ 22 22000 ]` (`lib/hosts.nix:115-118`), so the generated ACL never admits
  21027 across the tailnet — that firewall opening is unreachable by policy.
  Harmless in effect (Syncthing discovery), but it proves the two layers can
  diverge without any check firing. `main` currently matches only because
  someone hand-synced nine ports across two files in two different shapes
  (registry flattens TCP+UDP per `lib/hosts.nix:11`; the host splits them).
- **Fix (pick one):**
  1. Derive: a small globally-imported profile that sets
     `networking.firewall.interfaces.tailscale0.allowedTCPPorts/UDPPorts` from
     `hostMeta.tailscale.acceptFrom` (hosts add protocol-narrowing or extra
     ports explicitly, visible as deltas); or
  2. Check: a per-host invariant asserting
     `TCP ∪ UDP ports on tailscale0 ⊆/== union of acceptFrom values`.

  Either way, consider adding an optional protocol dimension to the registry
  schema (`lib/host-registry.nix:95-115`) so the registry can express what the
  firewall already does.

### 5. [I] Hosts re-declare what globally-imported profiles already provide — including one no-op `mkForce` with a misleading comment

The profile layer isn't trusted by its consumers; the same settings are
re-stated at the host layer:

- `nix.gc` (automatic/weekly/`--delete-older-than 7d`) is set in
  `modules/nixos/profiles/base.nix:45-49`, then re-declared verbatim in
  `hosts/homeserver-gcp/default.nix:85-89` and
  `hosts/gcp-builder/default.nix:77-81`.
- `hosts/mac/default.nix:130-132` claims to "Override the fleet default
  (`base.nix`: --delete-older-than 7d) with a tighter window" — and then
  `mkForce`s the **identical** value `"--delete-older-than 7d"`
  (`base.nix:48`). A no-op force with a comment that asserts the opposite of
  what the code does.
- `boot.zfs.forceImportRoot = false` is set fleet-wide via `mkDefault` at
  `base.nix:30`, then re-set at `hosts/homeserver-gcp/default.nix:119` and
  `hosts/gcp-builder/default.nix:37` (each with its own copy of the same
  comment).
- `modules/nixos/profiles/machine-common.nix:3-6` exists solely to provide
  `openssh.enable = true; openFirewall = false`, yet two of its three importers
  restate exactly that (`hosts/homeserver-gcp/default.nix:190-193`,
  `hosts/gcp-builder/default.nix:94-97`; `mac` restates it to add `hostKeys`,
  which is legitimate). As-is, machine-common is nearly vestigial.
- Duplicated terminfo package blocks: `hosts/gcp-builder/default.nix:84-91` and
  `hosts/homeserver-gcp/default.nix:92-101` carry the same four
  `*.terminfo` packages with the same comment — a natural `machine-common`
  (or "server-common") member.

Individually harmless (equal definitions merge), but the pattern means a future
change to a profile default will _not_ take effect on the hosts that shadow it,
which is precisely the drift the profile layer exists to prevent.

### 6. [I] Binary-cache identity is scattered across four host files

- R2 substituter URL + public key: `hosts/main/default.nix:115-121` and
  `hosts/mac/default.nix:122-128` (with a "keep in sync with CI" comment that
  is itself the smell).
- `main.local` cache key + cache.nixos.org key:
  `hosts/homeserver-gcp/default.nix:81-84` and
  `hosts/gcp-builder/default.nix:60-63`.

These are fleet-level facts. A signing-key rotation currently touches four
files plus CI config. **Fix:** one shared constants file under `lib/` (or
fields on the registry / a `profiles.nix.*` option) consumed by all hosts.

### 7. [I] Dead flake input and orphan profiles: `microvm`, `microvm-guest.nix`, `machine-dev.nix`

- `flake.nix:53-56` declares the `microvm` input. Nothing references it beyond
  the inputs block (repo-wide grep).
- `modules/nixos/profiles/microvm-guest.nix` (and through it
  `machine-dev.nix`, `microvm-guest.nix:8,15`) is imported by no host, test, or
  check. `CLAUDE.md:142-144` and `docs/security.md:340` still describe
  `machine-dev.nix` as a live broad-sudo exception, and
  `scripts/ci-plan.sh:28` carries a path-filter regex for a module that no
  output exercises.
- Cost: weekly `flake.lock` churn for an unused input, and an unexercised
  profile that can rot invisibly (no closure builds it, so `merge-gate` proves
  nothing about it).
- **Fix:** delete the input and, unless microvm guests are imminent, the two
  profiles + the doc references; or wire a minimal eval fixture so they're at
  least exercised.

### 8. [F] `scripts/ci-plan.sh` re-encodes the module import graph as shell regexes — with a real hole around observability

- `scripts/ci-plan.sh:24-32` hand-maps module paths to host sets. The mapping
  classifies `modules/nixos/profiles/observability/` as
  `module_server_hosts` (`ci-plan.sh:27`), which triggers only
  `profile_tests` + `homeserver_gcp_smoke` (`ci-plan.sh:156-159`).
- But the observability directory is **globally imported**
  (`modules/nixos/default.nix:7`) and load-bearing for every host: `main`/`mac`
  enable its collectors via `observability-client`
  (`hosts/main/default.nix:104-113`, `hosts/mac/default.nix:187-194`), and even
  `gcp-builder` enables it to satisfy `base.nix` (finding 1). A change to
  `collectors.nix` that breaks `main`'s closure or flips a `main` invariant
  never builds `main-ci`/`mac` pre-merge — `flake-eval` catches pure eval
  errors, but invariant checks are _built_ derivations
  (`lib/invariants.nix:583-599`) and host closures are path-gated.
- The unknown-module fallback is safe (`ci-plan.sh:99-104,165-170` →
  `select_all_hosts`), so the risk is confined to paths the regexes _do_ claim
  to understand — which is the insidious case.
- **Fix:** at minimum reclassify `observability/` as all-hosts. Structurally:
  derive host impact from the registry/import graph (even a generated
  path→host map checked by a test) instead of hand-curated regexes, or accept
  the cost and run all host closures on any `modules/` change.

### 9. [F] Per-host check wiring in `flake/checks.nix` is hand-assembled with no completeness guarantee

- `invariants-main` / `invariants-main-ci` / `invariants-homeserver-gcp` /
  `invariants-mac` are individually listed (`flake/checks.nix:601-620`);
  `gcp-builder` has none (defensible — but nothing records that decision).
  Sops bootstrap checks are hand-listed for exactly `homeserver-gcp` and `mac`
  (`flake/checks.nix:622-624`), while the _registry_ knows which hosts are
  sops-enabled (`sops = false` for gcp-builder, `lib/hosts.nix:93`).
- A 5th host gets registry-enforced sops parity
  (`checkSopsRecipientParity`, `flake/checks.nix:584-593`) but silently _no_
  invariant check and _no_ bootstrap check unless someone remembers
  this file. Rule 2's "verify with `invariants-<host>`" guidance
  (`docs/architecture.md`) assumes the check exists.
- **Fix:** generate the common per-host checks by mapping over
  `hostRegistry` (commonSystemInvariants + registryAssertions + bootstrap when
  `sops != false`), keeping the host-specific invariant lists as additive
  extras. That makes "every registry host has a baseline check" structural.

---

## Part 2 — Judgment calls

### 10. [F] Deploy nodes connect to the bare host name, ignoring the registry FQDN

`flake/deploy.nix:22-23` sets `hostname = name`, relying on MagicDNS search
domains on whatever machine runs `deploy`. Meanwhile an invariant insists every
deploy target _has_ tailnet metadata (`lib/invariants.nix:111-125`,
`flake/checks.nix:589-592`) — which deploy then doesn't consume. Similarly
`scripts/validate.sh:20` hardcodes `gcp-builder.tail90fc7a.ts.net` as the
builder default (env-overridable). `hostname = cfg.tailnetFQDN or name` (and a
`nix eval`-derived default in validate.sh) would make the registry the actual
source of deploy addressing. Counterargument: short names + MagicDNS are fine
in practice; this is consistency polish, not a bug.

### 11. [F] Tailnet domain repeated per host in the registry

`tail90fc7a.ts.net` appears in all four `tailnetFQDN`s
(`lib/hosts.nix:40,63,87,112`). A `tailnetDomain` constant with derived FQDNs
would make a tailnet rename one line. Counterargument: four literal, greppable
strings are honest; a derivation adds indirection for a rename that may never
happen. Lean: derive — `tailnetFQDN` is already documented as derived-feeling
metadata, and finding 10 would add a fifth copy site otherwise.

### 12. [F] Home Manager "config by specialArgs" instead of options

`skipHeavyPackages`, `enableSpotify`, and `hostName` are threaded as module
args with silent defaults (`flake/hosts.nix:91-99`;
`home/profiles/desktop.nix:4-5`; `home/profiles/workflow-packs/*.nix:5`;
`home/users/user/home.nix:5-7`). These are invisible to the module system: no
types, no docs, and a consumer that forgets to pass them silently gets the
default — e.g. the standalone `homeConfigurations.user`
(`flake/hosts.nix:143-155`) passes no `hostName`, so `home.nix` silently
assumes `"main"`. The repo already demonstrates the better pattern in the same
tree: `workflowPacks.<pack>.enable` options selected from registry metadata
(`flake/hosts.nix:40-45`). Migrating the three flags to HM options (e.g.
`fleet.skipHeavyPackages`) would be mechanical. Judgment call because the
current form works and the arg defaults are deliberate.

### 13. [F] `impermanence-base` hardcodes host disk-naming conventions

`modules/nixos/profiles/impermanence-base.nix:42-76` bakes
`/dev/mapper/cryptroot`, `@root`, `@root-blank`, and `old_roots` into the
shared rollback service. Both current users (`main`, `mac`) comply, but a third
impermanent host with a differently-named LUKS device fails **at boot in
initrd**, not at eval — the worst place to discover a convention. Options with
the current values as defaults (`device`, `rootSubvol`, `blankSubvol`) would
move the contract into the type system. Counterargument: conventions shared by
all hosts are also a feature; README markets this module as a pattern, though,
so parameterizing helps adopters too.

### 14. [I] Minor flake-level inconsistencies (grouped)

- **Three separate `import nixpkgs` instantiations** with diverging overlay
  sets: `flake.nix:120-127` (overlays, for checks/invariants),
  `flake/hosts.nix:13-20` (overlays, for `homeConfigurations`), and the
  perSystem one at `flake.nix:193-196` (**no overlays**, for packages/dev).
  Each instantiation costs eval time/memory, and the overlay divergence is the
  kind of thing that surprises later (a `packages.*` output can't see
  `lazyactions` today). One shared `mkPkgs` would do.
- **`lazyactions` pinned to `rev = "main"`** with a fixed-output hash
  (`flake.nix:90-91`). Reproducible until the first cache miss after upstream
  moves `main`, then the build breaks on a hash mismatch at an arbitrary future
  date. Pin a commit. Also: both overlays are inline package definitions in the
  flake entry, while `docs/architecture.md` §5 puts repo-owned packages under
  `packages/`.
- **Duplicate module exports:** `observability-stack` ≡
  `profiles-observability` and `observability-client` ≡
  `profiles-observability-client` (`flake.nix:243-249`); README documents only
  one set (`README.md:240-248`) and shows them as paths while `flake.nix`
  exports imported functions. Harmless aliasing, but one name per artifact is
  cleaner for a public contract.
- **`hostDriftInventory`** hardcodes `name = "homeserver-gcp"` and
  `expectedExtraTCPPorts` in the host file
  (`hosts/homeserver-gcp/default.nix:11-44`) — `hostMeta.name` is in scope, and
  the port list is a third copy of firewall facts (see finding 4).
- **`collectors.nix:16`** defines `prometheusPort = 9090` then hardcodes
  `port = 9090` at `collectors.nix:494` anyway (the constant is used at `:522`).

### 15. What was checked and found clean (so you don't re-audit it)

- **Layer 0 purity:** `lib/hosts.nix`, `lib/acl.nix`, `lib/host-registry.nix`,
  `lib/generators.nix` import no system modules; registry schema validation is
  throw-based, typed, and rejects unknown fields (`lib/host-registry.nix:65-171`).
- **Assertions used where prose would fail:** sops initrd-secrets boundary
  (`modules/nixos/profiles/sops-base.nix:19-24`), broad-trusted-user rejection
  (`modules/nixos/profiles/nix-trusted-users.nix:27-39`), fail2ban-with-SSH
  (`modules/nixos/profiles/security.nix:53-58`), cross-option observability
  contracts (`observability/collectors.nix:457-488`,
  `observability-client.nix:74-91`), ACL fail-fast on undefined source tags
  (`lib/acl.nix:27-36`).
- **Eval hygiene:** essentially no `with lib;` outside one `meta`
  (`packages/control-center/default.nix:92`), no risky `rec` in module code,
  specialArgs limited to a coherent set (`inputs`, `self`, `hostRegistry`,
  `hostMeta` — `flake/hosts.nix:66-73`), no import cycles found.
- **Side-effect gate (Rule 1):** the global imports in
  `modules/nixos/default.nix:3-10` match the documented list and are
  enable-gated or metadata-gated (`backup.nix:21` is inert without
  `hostMeta.backup.class`) — with finding 1 as the lone violation
  (`base.nix`'s unconditional activation script _is_ an unconditional side
  effect threaded through a gated module).
- **Hosts are thin where it counts:** `homeserver-gcp` keeps host-local
  modules option-shaped and namespaced (`profiles.homeserverGcpNginx`,
  `hosts/homeserver-gcp/nginx.nix:24`); main's gnarly hardware quirks stay in
  `hosts/main/`.

---

## Part 3 — Adding a 5th host: what actually changes

Enforced or intended (healthy):

1. `lib/hosts.nix` entry — schema-validated.
2. `hosts/<name>/` assembly — intended explicitness.
3. `.sops.yaml` recipients + secrets — **enforced** by
   `checkSopsRecipientParity` (`flake/checks.nix:584-588`).
4. deploy node, ACL, inventory — **generated** from the registry.

Unenforced, must-remember (the friction):

5. `flake/checks.nix`: `invariants-<host>` + sops bootstrap check (finding 9 —
   nothing fails if you forget).
6. `scripts/ci-plan.sh`: path regexes + host matrix entries (finding 8 — forget
   it and CI silently under-builds the new host).
7. tailscale0 firewall ports mirroring the registry `acceptFrom` (finding 4 —
   no parity check).
8. `flake/hosts.nix` `homeManagerHostModules` map if the host needs a per-host
   HM overlay (`flake/hosts.nix:31-34`) — small, discoverable.

Items 5–7 are exactly the three loops the registry was built to close; closing
them turns "add a host" from eight touchpoints into four.

---

## Top 3 refactors by leverage

1. **Make the public module exports honest** (findings 1, 2, and the fixture
   gap): decouple `mkPromScript` from `profiles-base`, remove the hardcoded
   `users.users.user` from `profiles-desktop`, and upgrade
   `miniFleetExampleFixture` (plus a new `profiles-base` fixture) to force
   `toplevel.drvPath`. This is the highest-leverage item because the README's
   entire public story rests on "the reusable building blocks work without the
   personal host assemblies" — which is currently false for two of the six
   exports, and the test style guarantees you'd never find out from CI.

2. **Close the registry→host enforcement loop** (findings 4, 9, 10): derive
   tailscale0 firewall ports (or add a parity invariant), generate per-host
   invariant/bootstrap checks from `hostRegistry`, and point deploy at
   `tailnetFQDN`. One theme, three edits, and the SSoT claim in
   `docs/architecture.md` Rule 3 becomes structurally true instead of
   convention-true.

3. **Delete the dead composition paths** (findings 3, 7, 5): remove the
   stubbed `homeserver-gcp` CI variant, the `microvm` input + orphan profiles,
   and the host-level re-declarations of profile defaults (including the
   misleading `mkForce` on mac). Pure deletion, no behavior change, and it
   eliminates the two places where "what CI builds" and "what actually
   deploys/runs" can quietly diverge. Fold the `ci-plan.sh` observability
   reclassification (finding 8) into the same pass.
