# Homeserver Goals

This is the remaining implementation roadmap for `homeserver-gcp`.

Current baseline: GCP `e2-medium` in `us-central1`, reachable through
Tailscale only, running Vaultwarden, Nginx with Tailscale-issued TLS, the LGTM
observability stack, and Backblaze B2 restic backups. Provisioning is automated
through `scripts/deploy-gcp.sh`.

Completed milestones have been folded into the durable docs:

- `README.md` for the current service surface, observability dashboards, and generated inventory.
- `docs/operations.md` for smoke tests, snapshots, and validation workflows.
- `docs/security.md` for exposure and ACL drift detection.
- `docs/restore-drill.md` for backup recovery procedure.
- `hosts/homeserver-gcp/CLAUDE.md` for host-specific operating notes.

## Difficulty Scale

| Difficulty | Meaning                                                                                         |
| :--------- | :---------------------------------------------------------------------------------------------- |
| Easy       | Small Nix/service change; low migration risk.                                                   |
| Medium     | Several modules or external systems; needs careful validation.                                  |
| Hard       | Stateful migration, security-sensitive design, CI/deploy plumbing, or external API integration. |

## Recommended Order

| Order | Goal                       | Difficulty | Status   | Why this order                                                                                       |
| :---- | :------------------------- | :--------- | :------- | :--------------------------------------------------------------------------------------------------- |
| 1     | Billing budgets and alerts | Easy       | Planned  | Cheap guardrail with immediate value; catches cost regressions before adding more provider services. |
| 2     | Cloud Monitoring           | Easy       | Planned  | Adds provider-side health signals that complement the self-hosted LGTM stack.                        |
| 3     | Secret Manager             | Medium     | Planned  | Reduces reliance on instance metadata and local secret injection for bootstrap and recovery paths.   |
| 4     | Cloud Logging              | Medium     | Planned  | Preserves serial console and audit visibility when the VM is unreachable over Tailscale.             |
| 5     | Cloud DNS                  | Medium     | Deferred | Useful once there is a concrete need for managed naming beyond raw Tailscale hostnames.              |
| 6     | Cloud KMS                  | Medium     | Deferred | Worth adding only when customer-managed keys or audited key separation become operational needs.     |
| 7     | Service composition DSL    | Hard       | Deferred | Worth doing only after Vaultwarden plus at least one more service show the real abstraction shape.   |

## Recently Completed

- `Tailscale-aware Grafana SSO` — done on `homeserver-gcp`: nginx now gates `/grafana/` through a local Tailscale-aware auth helper, Grafana trusts auth-proxy headers from localhost, and the break-glass path remains local admin access over SSH port-forwarding.
- `Typed Nginx/timer generators` — done on `homeserver-gcp`: `lib/generators.nix` now exposes a narrow nginx proxy-location helper for `proxyPass`, websocket, basic-auth, and escape-hatch config, plus a systemd timer helper for schedule and jitter. Vaultwarden, Grafana, observability ingest routes, and repeated maintenance timers consume it; one-off aliases and auth subrequest internals remain hand-written.

## Goal Details

### 1. Billing Budgets and Alerts

Add GCP billing budgets and threshold notifications for the homeserver project.

Implementation:

- Define monthly budget thresholds that fit the steady-state `e2-medium` + disk + snapshot cost profile.
- Route alert notifications to an operator-owned mailbox or existing incident channel.
- Document expected baseline spend and the meaning of each alert threshold.

Acceptance:

- The project emits warning notifications before spend can drift materially.
- Budget configuration is documented well enough to review or recreate during project recovery.

### 2. Cloud Monitoring

Add provider-side monitoring for VM lifecycle, resource saturation, and missing-heartbeat conditions.

Implementation:

- Enable the minimum GCP monitoring surface needed for Compute Engine health, CPU, memory, disk, and uptime alerts.
- Keep the boundary clear: provider-side alerts should cover host and control-plane failure modes, not replace LGTM dashboards.
- Document which incidents should page from GCP versus which remain internal observability concerns.

Acceptance:

- A stopped VM, failed boot, or prolonged host-level degradation can be detected without depending on the VM's own stack.
- Alert ownership and expected signal quality are documented.

### 3. Secret Manager

Adopt GCP Secret Manager for secrets that benefit from provider-managed storage, IAM scoping, and audit trails.

Implementation:

- Identify which secrets should remain in `sops` and which are better stored in Secret Manager.
- Prioritize bootstrap and recovery-sensitive secrets that are currently injected via instance metadata or other ad hoc paths.
- Keep the retrieval path explicit and auditable; do not hide secret flow behind broad ambient permissions.

Acceptance:

- Secret placement has a clear rationale instead of mixing storage backends arbitrarily.
- Bootstrap and runtime secret handling is less dependent on long-lived metadata values.

### 4. Cloud Logging

Add centralized provider-side logging for recovery and audit scenarios.

Implementation:

- Capture the GCE serial console and relevant platform or audit logs needed during host recovery.
- Retain enough history to support post-incident analysis without creating a noisy duplicate of application logs already stored in Loki.
- Document the operator workflow for reading logs when Tailscale or SSH access is unavailable.

Acceptance:

- Recovery-relevant logs remain accessible when the host is down or isolated from the tailnet.
- The project documents which logs live in GCP versus which remain in self-hosted observability.

### 5. Cloud DNS

Introduce managed DNS only if there is a concrete naming problem that Tailscale DNS does not solve cleanly.

Implementation:

- Decide whether the real need is public DNS, private DNS, or split-horizon DNS before provisioning anything.
- Prefer narrow, explicit zones over broad DNS indirection that hides service exposure decisions.
- Document ownership of records and how DNS choices interact with Tailscale-issued TLS and tailnet-only access.

Acceptance:

- DNS exists to solve a real naming or routing problem, not as speculative infrastructure.
- Exposure and certificate implications are understood before records are published.

### 6. Cloud KMS

Add customer-managed key support when default GCP-managed encryption is no longer sufficient.

Implementation:

- Define the concrete requirement first: compliance, key separation, rotation control, or auditability.
- Scope KMS use narrowly, such as boot disk encryption or specific secret-wrapping flows, instead of adopting it project-wide by default.
- Document operational consequences, including key rotation, failure modes, and recovery constraints.

Acceptance:

- KMS adoption is justified by a real security or compliance need.
- Key ownership, rotation procedure, and break-glass recovery expectations are documented.

### 7. Service Composition DSL

Build this only after the server has enough services to justify the abstraction.

Implementation:

- Prototype around Vaultwarden and AdGuard, not around imaginary services.
- Wire hardening, observability, firewall, Nginx, and backup hooks from one typed service declaration.
- Keep escape hatches for service-specific systemd hardening and Nginx locations.

Acceptance:

- Adding a normal homeserver service requires fewer cross-cutting edits.
- The DSL does not hide security-sensitive exposure or backup decisions.

## Notes

- `Automated deploy pipeline` and `Secret rotation ritual` have been moved to `docs/backlog.md` and are no longer active homeserver priorities.
- Broad service DSL work is now the only active homeserver roadmap item, and it should stay deferred until there are enough repeated service patterns to justify the abstraction.
