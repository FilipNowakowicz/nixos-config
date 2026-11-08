# Observability Stack

`nixosModules.observability-stack` exposes the reusable monitoring profile from this
repo. It keeps the existing `profiles.observability` option tree so hosts that
already import the profile do not need a migration.

## Importing from your own flake

Add this flake as an input and import the module(s) you need:

```nix
# flake.nix
{
  inputs.nixos-fleet.url = "github:FilipNowakowicz/nixos-config";

  outputs =
    {
      nixpkgs,
      nixos-fleet,
      ...
    }:
    {
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          nixos-fleet.nixosModules.observability-stack
          nixos-fleet.nixosModules.observability-client
          ./configuration.nix
        ];
      };
    };
}
```

Or, inside a module that already receives `inputs`:

```nix
{
  imports = [
    inputs.nixos-fleet.nixosModules.observability-stack
    inputs.nixos-fleet.nixosModules.observability-client
  ];
}
```

## Local single-node stack

Use this mode when Grafana, Loki, Prometheus, Alertmanager and Alloy all run on one host.

```nix
{
  imports = [
    inputs.nixos-fleet.nixosModules.observability-stack
  ];

  profiles.observability = {
    enable = true;
    grafana = {
      enable = true;
      adminPasswordFile = config.sops.secrets.grafana_admin_password.path;
      secretKeyFile = config.sops.secrets.grafana_secret_key.path;
    };
    loki.enable = true;
    alerts.enable = true;
    collectors = {
      metrics.enable = true;
      logs.enable = true;
    };
  };
}
```

Dashboards are declared under `profiles.observability.dashboards`. Built-in
dashboards default to disabled and can be enabled or replaced by host-level
configuration.

## Remote client mode

`nixosModules.observability-client` configures a host to ship metrics and logs to a central stack. The domain, URL paths, username, group, and secret
backend are explicit options.

```nix
{
  imports = [
    inputs.nixos-fleet.nixosModules.observability-stack
    inputs.nixos-fleet.nixosModules.observability-client
  ];

  profiles.observability-client = {
    enable = true;
    remoteEndpoint = {
      host = "observability.example.ts.net";
      metricsPath = "/obs/prometheus/api/v1/write";
      logsPath = "/obs/loki/loki/api/v1/push";
    };
    ingestAuth = {
      username = "telemetry";
      group = "telemetry-ingest";
      passwordFile = config.age.secrets.observability-ingest-password.path;
    };
  };
}
```

The client module does not create secrets itself. Declare the password secret with sops-nix, agenix, or another backend
at the host boundary, then pass that path into `ingestAuth`.

## Decision: minimal personal-server stack

Issue [#474](https://github.com/FilipNowakowicz/nixos-config/issues/474),
following the homeserver design review (#459), removes **Mimir, Tempo and the
OpenTelemetry collector**, including the OTLP trace pipeline. Keep **Prometheus
as the single metrics store, Loki, Grafana, Alloy for logs, node and blackbox
exporters, AdGuard, the GitHub recovery runner, and NixOS rather than containers**.
The tailnet DNS policy is unchanged.

This is a small personal server. Only Grafana and AdGuard application data are
backed up independently; multiple telemetry backends add failure modes and
upkeep without corresponding value. There are no applications producing useful
traces, and one server does not need horizontally scalable metrics storage.
Mimir's ring configuration caused a boot crash loop during the GCP project move.
Revisit only with a new reason: several hosts needing shared long-term metrics
beyond one Prometheus, or a self-written service requiring distributed tracing.
The `observabilityStaysMinimal` invariant checks every registry host and rejects
`services.mimir`, `services.tempo` or `services.opentelemetry-collector` enablement.
Their names remain only here and in that guard and its regression tests.

### Migration and manual cleanup (after a separately authorized deployment)

No deployment or cleanup is performed by this change. Prometheus now keeps 30
days on the homeserver, accepts remote write through the exact authenticated
`/obs/prometheus/api/v1/write` nginx route, evaluates the shared infrastructure
rules, and delivers them to the loopback Alertmanager with the existing
`alertmanager_webhook_url`. Clients retain a 24-hour local buffer. Metrics
history from the removed backend is not imported; the existing Prometheus TSDB
supplies its recent local samples and new remote writes accumulate from cutover.

Treat alert continuity as a migration gate, not just a successful system switch:

1. Before the production switch, arrange an overlapping independent evaluator
   and notification receiver using the same rules and off-host webhook. Keep
   the old evaluation/delivery path active until that overlap has been tested
   end to end; the off-box heartbeat and direct failed-unit notifier remain
   enabled throughout. Do not rely on the heartbeat as a substitute for rules.
2. Switch the homeserver first; confirm `/api/v1/rules` on `127.0.0.1:9090`
   contains every infrastructure rule, `/api/v1/alertmanagers` discovers
   `127.0.0.1:9093`, and send a controlled test alert through to the real
   notification target. Keep overlap through rule `for` periods and verify
   pending/firing alerts; pending state and silences do not migrate automatically.
3. Switch `main` to the new authenticated ingest path, then confirm its samples
   with `up{host="main"}` at the receiver and inspect remote-write failures and
   pending samples. Pause or roll back if delivery fails. If rolling back the
   server, roll back the client route together; do not retire the overlap until
   both metrics and notifications have been verified. This PR is not authority
   to merge or trigger the existing automatic production deployment.
4. Once the new stack is verified and rollback no longer needs the old data,
   manually inspect then remove `/var/lib/mimir`, `/var/lib/tempo`, and any
   corresponding `/var/lib/private/mimir`, `/var/lib/private/tempo` and retired
   collector state (including `/var/lib/private/opentelemetry-collector`, if
   present). Confirm the retired units are absent/inactive and the paths are
   not mount points before removal. Never remove `/var/lib/prometheus2`,
   `/var/lib/alertmanager`, `/var/lib/loki`, `/var/lib/grafana` or AdGuard state.
   No activation script automatically deletes data.

The `otel-env` template is removed from `main`. Its input
`observability_ingest_password` remains required by Prometheus and Alloy;
no encrypted secret becomes unused, and encrypted files are unchanged.
Grafana's provisioned datasource list prunes retired datasources on restart;
all metrics panels reference the new Prometheus UID.

### Historical evidence retained from archived learning notes

The following inactive learning records are retained here with their original
identifiers and evidence. Their component-specific proposals describe the old
stack; they are superseded by this decision and must not re-enable its services.
General lessons about runtime tests, secret permissions and configuration
validation still apply to the retained stack.

#### 2026-06-10-dynamicuser-sops-secret-permissions

```yaml
schema: learning-candidate/v1
id: 2026-06-10-dynamicuser-sops-secret-permissions
date: 2026-06-10
expires: 2026-12-10
status: promoted

route: promote-doc
best_form: doc

evidence: [pr-#153-fix-commit-254a64e, hosts/homeserver-gcp/default.nix:268-302-mimir-webhook-pattern, hosts/homeserver-gcp/adguard.nix:8-21]
observation: PR153 wired a default-mode (root:root 0400) sops secret into adguardhome's preStart, but adguardhome runs with DynamicUser=true so preStart executes as the dynamic user and cannot read the secret - service would fail to start. CI (checks-light, homeserver-gcp-smoke) stayed green because the smoke test does not import adguard.nix. The repo already has the correct fix pattern (mimir-webhook: root-owned secret, mode=0440, static supplementary group joined via systemd.services.<name>.serviceConfig.SupplementaryGroups) but it lives only as an inline comment in default.nix, not discoverable when adding a new DynamicUser+sops secret elsewhere.
proposed_upgrade: Document the DynamicUser+sops-secret supplementary-group pattern (mode=0440 + static users.groups.<x> + serviceConfig.SupplementaryGroups) in docs/security.md secrets section, and consider an invariant/lint that flags a sops.secrets.* path referenced inside a DynamicUser service's preStart/ExecStart when the secret has default owner/group/mode.
```

#### 2026-06-13-observability-profile-test-misses-tempo-mimir

```yaml
schema: learning-candidate/v1
id: 2026-06-13-observability-profile-test-misses-tempo-mimir
date: 2026-06-13
expires: 2026-09-13
status: superseded

route: implement-fix
best_form: test

evidence:
  [
    tests/nixos/profile-observability.nix:83-104,
    issue-#252,
    issue-#267,
    pr-#251,
  ]
observation: weekly flake.lock PR #251 bumped Tempo 2.10.5->3.0.1 (config schema break + new Kafka-dependent live-store module, #252) and Mimir to 3.1.0 (new default *:7946 memberlist listener, fails check-host-drift.sh on homeserver-gcp); merge-gate passed and auto-merged because tests/nixos/profile-observability.nix only wait_for_unit's loki/alloy (and stub-ingest/prometheus in the auth VM), never enabling or checking tempo.service or mimir.service
proposed_upgrade: extend tests/nixos/profile-observability.nix to enable services.tempo and services.mimir on the obs VM and wait_for_unit("tempo.service")/wait_for_unit("mimir.service"), so future package bumps to these backends fail merge-gate instead of breaking homeserver-gcp at deploy/runtime
```

#### 2026-06-14-nixos-test-nodes-miss-flake-inputs-specialarg

```yaml
schema: learning-candidate/v1
id: 2026-06-14-nixos-test-nodes-miss-flake-inputs-specialarg
date: 2026-06-14
expires: 2026-09-14
status: superseded

route: implement-fix
best_form: test
evidence:
  [
    "pr-#268 added inputs.nixpkgs-tempo-2105 dependency in modules/nixos/profiles/observability/backends.nix:16,33",
    "Deploy homeserver-gcp run 27507939669 validate job failed: 'error: attribute inputs missing' building nodes.server.system.build.toplevel via tempo overlay",
    "fix: tests/nixos/homeserver-gcp-smoke.nix added node.specialArgs = { inherit inputs; }; verified by nix build .#legacyPackages.x86_64-linux.ciTests.homeserver-gcp-smoke EXIT 0",
  ]
observation: nixos-runTest-nodes-do-not-receive-flake-inputs-as-module-arg-so-a-profile-depending-on-inputs-passes-host-closures-and-lazy-light-fixtures-but-fails-when-a-vm-test-actually-builds-the-node-closure
proposed_upgrade: add-light-lane-fixture-that-forces-system.build.toplevel.drvPath-of-observability-profile-with-tempo.enable-so-inputs-dependency-regressions-fail-fast-instead-of-only-in-kvm-smoke-test
type: workflow-gotcha
dedupe_key: nixos-tests:flake-inputs-not-threaded-into-test-nodes
triggers:
  [
    tests/nixos/*.nix,
    "nixosTest/runTest node importing a profile that uses the inputs module arg",
    "error: attribute 'inputs' missing while building nodes.*.system.build.toplevel",
  ]
targets: [tests/nixos/homeserver-gcp-smoke.nix, flake/checks.nix]
risk: forcing-toplevel-in-light-lane-adds-build-cost-if-scoped-too-broadly
```

#### 2026-06-15-uncommitted-work-destroyed-by-next-issue-reset

```yaml
schema: learning-candidate/v1
id: 2026-06-15-uncommitted-work-destroyed-by-next-issue-reset
date: 2026-06-15
expires: 2026-12-15
status: superseded

route: implement-fix
best_form: test

evidence:
  [
    ".agents/state/outcomes/2026-06-15T12:20:17Z-issue-320-failure.json: exit_code=124, blocker='claude session exceeded AGENT_INNER_TIMEOUT_SECONDS=900', git_dirty=[' M flake/checks.nix',' M tests/nixos/profile-observability.nix'], head_branch=issue-320-observability-tempo-mimir-tests, head_sha=151e8f4 (== origin/main, no commit made)",
    "session log .agents/state/sessions/2026-06-15T12:05:08Z-issue-320.log: 31 Bash tool calls, zero 'git commit' calls -- the inner session edited the two files then got stuck in a ScheduleWakeup poll loop waiting on a background profile-tests VM build until the 900s timeout killed it",
    "post-mortem on gcp-agent: branch issue-320-observability-tempo-mimir-tests exists but at commit 151e8f4 (identical to main); `git status --porcelain` clean; `git stash list` empty -- the two edited files' content is gone, only recoverable by redoing the implementation",
  ]
observation: scripts/agent-run-issue.sh's per-issue setup (`git fetch && git reset --hard origin/main` before starting the next queued issue, e.g. #323 after #320 timed out) silently destroys any uncommitted working-tree changes left by a prior issue's session that hit AGENT_INNER_TIMEOUT_SECONDS before committing -- worse than the known stranded-pushed-branch case ([[2026-06-14-runner-strands-completed-work-when-cap-hits-before-pr]]), this is unrecoverable data loss with no branch, no stash, no diff saved anywhere.
proposed_upgrade: before `git reset --hard origin/main` (or right after a timeout/SIGTERM is detected for the inner session), check `git status --porcelain`; if non-empty, commit the dirty tree to the issue's head_branch with a clear WIP message and push it (or at minimum `git stash push` with a labeled message and record the stash ref in the outcome record) so a human can recover the work, instead of silently discarding it. Add a regression test that simulates a timed-out session leaving dirty files and asserts the next-issue setup preserves them on a branch/stash rather than reset --hard wiping them.

type: behavior-upgrade
dedupe_key: agent-run-issue:uncommitted-dirty-tree-destroyed-by-next-issue-reset
triggers:
  [
    scripts/agent-run-issue.sh,
    AGENT_INNER_TIMEOUT_SECONDS,
    "git reset --hard origin/main",
    multi-issue --issues batch,
  ]
targets: [scripts/agent-run-issue.sh]
risk: high if unfixed -- any multi-issue dispatch where an earlier issue times out mid-edit loses that work entirely
```

#### 2026-06-16-dry-run-binary-before-config-schema-migration

```yaml
schema: learning-candidate/v1
id: 2026-06-16-dry-run-binary-before-config-schema-migration
date: 2026-06-16
expires: 2026-12-16
status: promoted

route: promote-skill
best_form: skill

evidence:
  [
    pr-#335,
    "modules/nixos/profiles/observability/backends.nix tempo.settings 3.x rewrite verified by nix build of inputs.nixpkgs.legacyPackages tempo (3.0.1) then tempo -config.file=cand.yaml -target=all",
  ]
observation: "major-version config-schema migrations (e.g. Tempo 2.x->3.x in backends.nix) are validated fastest by building the exact nixpkgs binary and dry-running the candidate YAML (parse + brief boot) BEFORE editing the Nix module; this confirmed exact 3.x keys (live_store/block_builder/backend_scheduler.provider.compaction.compaction.block_retention) and disproved the assumed Kafka requirement for monolithic target=all, where docs/issue text were stale/wrong"
proposed_upgrade: "add a step to nix-verification-loop (or a new note) for service config-schema bumps: nix build the package from the flake's nixpkgs input, run the binary against the candidate config to confirm keys parse, then edit the module — cheaper and more authoritative than docs or a full closure build"
type: behavior-upgrade
```

#### 2026-07-23-mimir-frontend-address-autodetect

```yaml
schema: learning-candidate/v1
id: 2026-07-23-mimir-frontend-address-autodetect
date: 2026-07-23
expires: 2027-01-23
status: promoted

route: promote-doc
best_form: doc

evidence: [modules/nixos/profiles/observability/backends.nix:120-152, `mimir -config.file=<path> -print.config` output showing `frontend.instance_interface_names: [ens4, tailscale0]` and `frontend.address: ""`, journalctl -u mimir `msg="error notifying frontend about finished query" frontend=10.154.0.8:9095`, fix verified live via `curl http://127.0.0.1:9009/prometheus/api/v1/query?query=up` (30s timeout -> 200 in ~11ms)]
observation: backends.nix already documents "every ring needs instance_addr=127.0.0.1 because Mimir auto-detects the GCE interface" but only applied it to sharding rings; `frontend.address` has the identical GCE-interface-autodetection failure mode but is not a ring and was missed, breaking all Grafana/Mimir queries ("no data") while ingestion kept working, which masked the cause. First fix attempt targeted `query_scheduler.ring.instance_addr`, which had zero effect because this deployment's `query_scheduler.service_discovery_mode` defaults to `dns` not `ring` (that ring block is unused). `mimir -print.config` (resolved effective config, not the input yaml) was what actually surfaced both the wrong assumption and the correct fix location.
proposed_upgrade: add a note near the existing instance_addr comment in backends.nix (or docs/architecture.md) that Mimir has multiple independent GCE-interface-autodetection points beyond sharding rings (frontend.address at minimum), and that `mimir -config.file=<path> -print.config` is the fast way to find which resolved config block owns a bad auto-detected address before guessing based on which port a connection-refused error mentions.
resolution: the fix and its "same class of bug as the rings, just on the
  frontend" explanation were already in backends.nix; added only the missing
  piece, a pointer to `mimir -print.config` as the diagnostic technique for
  the next independent auto-detection point.
```
