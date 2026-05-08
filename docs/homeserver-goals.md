# Homeserver Goals

This is the implementation roadmap for `homeserver-gcp`.

Current baseline: GCP `e2-medium` in `us-central1`, reachable through
Tailscale only, running Vaultwarden, Nginx with Tailscale-issued TLS, the LGTM
observability stack, and Backblaze B2 restic backups. Provisioning is automated
through `scripts/deploy-gcp.sh`.

## Difficulty Scale

| Difficulty | Meaning                                                                                         |
| :--------- | :---------------------------------------------------------------------------------------------- |
| Easy       | Small Nix/service change; low migration risk.                                                   |
| Medium     | Several modules or external systems; needs careful validation.                                  |
| Hard       | Stateful migration, security-sensitive design, CI/deploy plumbing, or external API integration. |

## Recommended Order

| Order | Goal                                  | Difficulty | Status   | Why this order                                                                                      |
| :---- | :------------------------------------ | :--------- | :------- | :-------------------------------------------------------------------------------------------------- |
| 1     | Backup verification and restore drill | Medium     | Done     | Backups already run; prove they restore before adding more state.                                   |
| 2     | Live endpoint smoke tests             | Medium     | Done     | Gives a fast safety net for later changes to Nginx, Vaultwarden, Grafana, and ingest paths.         |
| 3     | LGTM alert tuning                     | Medium     | Done     | The stack is live; make it detect disk, service, and backup failures before expanding scope.        |
| 4     | Vaultwarden websocket notifications   | Easy       | Done     | Small user-facing improvement with limited blast radius.                                            |
| 5     | Disk layout decision                  | Medium     | Done     | Root-only layout is intentional; split storage only when a concrete retention or quota need exists. |
| 6     | GCE disk snapshots                    | Medium     | Done     | Daily 7-day provider-local boot disk snapshots are attached for fast rollback alongside restic.     |
| 7     | Local DNS and ad-blocking             | Medium     | Done     | First new service; depends on backup, smoke, alert, and disk posture being clear.                   |
| 8     | Secret rotation ritual                | Medium     | Deferred | Valuable once deploy/smoke paths can prove rotation did not break the server.                       |
| 9     | ACL drift detection                   | Medium     | Later    | The ACL package exists; live API comparison is useful but not a blocker for new services.           |
| 10    | Vulnix/CVE dashboard                  | Medium     | Later    | Security visibility is useful after alerting conventions are settled.                               |
| 11    | Automated deploy pipeline             | Hard       | Later    | High leverage, but design depends on runner placement, KVM needs, and smoke-test coverage.          |
| 12    | Tailscale-aware Grafana SSO           | Hard       | Later    | Removes a secret, but authentication mistakes can lock out observability.                           |
| 13    | Host introspection into LGTM          | Medium     | Later    | Adds useful audit signals after retention/cardinality limits are tuned.                             |
| 14    | Typed Nginx/timer generators          | Medium     | Later    | Refactor after enough repeated service patterns exist.                                              |
| 15    | Service composition DSL               | Hard       | Deferred | Worth doing only after Vaultwarden plus at least one more service show the real abstraction shape.  |

## Goal Details

### 1. Backup Verification And Restore Drill

`homeserver-gcp` already uses `services.restic.backups.b2` with the shared
`critical` retention policy from `modules/nixos/profiles/backup.nix`.

Implementation:

- Add a periodic `restic check --read-data-subset=1G` systemd timer.
- Export backup age/check status into Grafana.
- Document a quarterly restore drill that restores Vaultwarden and Grafana data into a disposable target.
- Keep B2 restic as the source of truth for application data; do not duplicate retention policy in host-local config.

Acceptance:

- `nix build .#checks.x86_64-linux.invariants-homeserver-gcp --no-link` still passes.
- A restore drill has an operator command path and a recorded result date.

### 2. Live Endpoint Smoke Tests

Extend checks beyond Nix evaluation so deployments catch broken routing and auth
before the server is considered healthy.

Implementation:

- Probe `/` for Vaultwarden reachability through Nginx.
- Probe `/grafana/` for login page reachability and sub-path correctness.
- Probe observability ingest paths for expected auth behavior.
- Keep tests credential-light; prefer checking status codes and auth boundaries over embedding high-privilege secrets.

Acceptance:

- A single validation command can run the homeserver build plus endpoint smoke tests.
- Failed Nginx location, TLS, or auth wiring fails validation before a deploy is marked successful.

### 3. LGTM Alert Tuning

The LGTM stack is live; the next step is practical alerting rather than more
dashboards for their own sake.

Implementation:

- Alert on disk usage above 80%.
- Alert on failed systemd units and repeated service restarts.
- Alert on restic backup age/check failure.
- Tune Loki and Mimir retention/cardinality before adding noisy services.

Acceptance:

- Grafana shows the backup, disk, and service-health panels on the fleet dashboard.
- Alert rules have thresholds documented in the dashboard or adjacent module.

### 4. Vaultwarden Websocket Notifications

Enable instant sync for clients while keeping the public surface tailnet-only.

Implementation:

- Enable Vaultwarden websocket support if required by the NixOS module version.
- Add the Nginx `/notifications/hub` websocket location.
- Add a smoke check for the location so future Nginx refactors do not break it.

Acceptance:

- Mobile/desktop Vaultwarden clients receive updates without manual sync.
- Nginx still only allows inbound HTTPS on `tailscale0`.

### 5. Disk Layout Decision

Resolve storage layout before adding services that create durable state or high
write volume.

Decision: keep the current root-only layout unless a concrete need for isolated
retention emerges. `hosts/homeserver-gcp/disko.nix` allocates one 512 MB EFI
system partition and one ext4 root filesystem that consumes the rest of the GCE
boot disk. There is no `/persist` volume or unused data partition.

A separate filesystem is useful only if Loki, Mimir, or restic cache need
independent quotas or lifecycle management. If that need appears later, split
only the specific high-churn paths and document how those mounts are restored.

Implementation:

- Verified `hosts/homeserver-gcp/disko.nix` matches the intended root allocation.
- Keeping root-only; stale `/persist` wording has been scoped away from `homeserver-gcp`.
- No split data mounts are configured.

Acceptance:

- Disk layout docs, `disko.nix`, and the deployed VM agree.
- There is no unused partition reserved without an owner.

### 6. GCE Disk Snapshots

Add daily managed snapshots as a fast rollback layer. This is not a replacement
for restic because snapshots are provider-local and VM-shaped.

Implementation:

- Added an OpenTofu snapshot schedule for the homeserver boot disk.
- Retain 7 daily snapshots by default.
- Documented when to use snapshots vs restic restores.

Acceptance:

- Snapshot policy is visible in infrastructure code.
- Snapshot retention is short and explicitly separate from application backup retention.

### 7. Local DNS And Ad-Blocking

AdGuard Home is the best first new service because it is useful, observable, and
has clear operational boundaries.

Implementation:

- Deploy AdGuard Home bound to tailnet-reachable interfaces only.
- Integrate with Tailscale MagicDNS deliberately; avoid exposing DNS on public GCE interfaces.
- Export AdGuard metrics or logs into LGTM.
- Add AdGuard state to restic if it contains configuration that is not fully declarative.

Acceptance:

- Tailnet clients can opt into AdGuard DNS.
- DNS service health and query/block counts are visible in Grafana.
- Failure mode is documented so DNS issues do not block server access.

### 8. Secret Rotation Ritual

Make rotation repeatable before secrets age indefinitely.

Implementation:

- Document cadence per secret: Tailscale auth key, Grafana admin password, Grafana secret key, restic password, B2 credentials, and observability ingest credentials.
- Add a low-friction checklist for rotating each secret through sops and deploy.
- Surface days since last rotation in Grafana if the metadata can be represented cleanly.

Acceptance:

- Each secret has an owner, rotation trigger, and command path.
- Rotation does not require rediscovering deployment order from scratch.

### 9. ACL Drift Detection

The rendered `tailscale-acl` package exists; the missing piece is comparing it
with the live Tailscale policy.

Implementation:

- Add a CI check that fetches the live ACL through the Tailscale API.
- Diff it against the rendered ACL artifact.
- Fail only on real policy drift, not formatting noise.

Acceptance:

- Checked-in ACL intent and live tailnet ACL cannot silently diverge.

### 10. Vulnix/CVE Dashboard

Turn closure vulnerability data into a recurring operational signal.

Implementation:

- Schedule `vulnix` against `/run/current-system`.
- Convert results into a small JSON/textfile exporter.
- Alert on newly introduced critical vulnerabilities.

Acceptance:

- Grafana shows current critical/high vulnerability counts.
- Known tolerated findings have an explicit suppression path.

### 11. Automated Deploy Pipeline

Automate deployment only after smoke tests are useful enough to catch bad
rollouts.

Recommended design: split responsibilities. Run lint, eval, and homeserver
builds on a lightweight always-on runner. Keep KVM-dependent VM tests on `main`
or another KVM-capable machine.

Implementation:

- Package a self-hosted GitHub Actions runner as a NixOS service.
- Decide whether the always-on runner lives on `homeserver-gcp` or a different host.
- Run smoke tests before deploy.
- Deploy `homeserver-gcp` first, verify, then deploy `main` if needed.

Acceptance:

- No deployment pushes directly to `main`.
- Failed validation blocks rollout.
- Runner secrets have a rotation/removal procedure.

### 12. Tailscale-Aware Grafana SSO

Replace Grafana local admin login with tailnet identity only after the proxy
and break-glass story is clear.

Implementation:

- Evaluate `tailscale serve` or an auth proxy that injects verified identity headers.
- Map allowed Tailscale identities to Grafana roles.
- Keep a documented emergency admin path until SSO has been proven.

Acceptance:

- Grafana access is tied to Tailscale identity.
- Removing the Grafana admin password does not remove break-glass access.

### 13. Host Introspection Into LGTM

Feed security and inventory signals into the existing observability system.

Implementation:

- Start with one source: `lynis`, `auditd`, or `osquery`.
- Ship results to Loki with bounded labels.
- Add dashboards only for actionable findings.

Acceptance:

- The signal produces low-noise findings that lead to concrete action.
- Log labels do not create high-cardinality pressure.

### 14. Typed Nginx/Timer Generators

Extend the existing typed generator approach where it reduces mistakes in
repeated service plumbing.

Implementation:

- Add typed Nginx location generation for proxy target, auth, and websocket settings.
- Add typed timer generation for schedule plus jitter.
- Convert only repeated patterns; do not generalize one-off service config.

Acceptance:

- Generated config is simpler to review than hand-written Nix.
- At least two services consume the generator before it is considered stable.

### 15. Service Composition DSL

Build this only after the server has enough services to justify the abstraction.

Implementation:

- Prototype around Vaultwarden and AdGuard, not around imaginary services.
- Wire hardening, observability, firewall, Nginx, and backup hooks from one typed service declaration.
- Keep escape hatches for service-specific systemd hardening and Nginx locations.

Acceptance:

- Adding a normal homeserver service requires fewer cross-cutting edits.
- The DSL does not hide security-sensitive exposure or backup decisions.

## Removed Or Deferred

These items were intentionally changed from the old roadmap:

- The self-hosted deploy pipeline moved later because useful smoke tests should exist before deployment automation.
- Broad service DSL work moved to deferred because premature abstraction would make the next service harder, not easier.
