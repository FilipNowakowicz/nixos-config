# Homeserver Goals

Remaining implementation roadmap for `homeserver-gcp`.

Current baseline: GCP `e2-medium` in `europe-west2` (`europe-west2-a` zone by
default), reachable through Tailscale only, running Vaultwarden, AdGuard Home,
Nginx with Tailscale-issued TLS, the LGTM observability stack, and Backblaze B2
restic backups (with weekly integrity check + daily restore canary). Daily GCE
boot-disk snapshots and a public-SSH edge deny are managed in `infra/`.
Provisioning is automated through `scripts/deploy-gcp.sh`.

Completed milestones live in the durable docs:

- `README.md` — service surface, dashboards, generated inventory.
- `docs/operations.md` — smoke tests, snapshots, validation workflows.
- `docs/security.md` — exposure and ACL drift detection.
- `docs/restore-drill.md` — backup recovery procedure.
- `hosts/homeserver-gcp/CLAUDE.md` — host-specific operating notes.

## Framing

The host self-monitors well, but **every alerting component (Mimir ruler,
Alertmanager, the ntfy webhook) runs on the host it watches** — if the VM dies,
nothing fires. The provider-native checklist (Cloud Monitoring / Logging /
Secret Manager) was the wrong lens: a tailnet-only host has no public endpoint
for an external uptime probe, and there is no real metadata-secret reliance to
migrate. The active set below is reshaped around the one genuine gap —
**off-box liveness** — plus small, high-value hardening and verification.

## Active Goals

| Order | Goal                                      | Difficulty | Status                          | Why                                                                             |
| :---- | :---------------------------------------- | :--------- | :------------------------------ | :------------------------------------------------------------------------------ |
| 1     | Off-box dead-man's-switch                 | Easy       | Done — deployed + verified      | The only real gap: off-box liveness when the VM (and its on-box alerting) dies. |
| 2     | Vaultwarden DR canary extension           | Easy       | Done — deployed + verified      | Proves the crown-jewel DB actually opens, not just that the repo restores.      |
| 3     | Shielded VM (vTPM + integrity monitoring) | Easy       | Done — already active, codified | Cheap hardware root-of-trust + boot-integrity baseline.                         |
| 4     | Terraform drift guard                     | Easy       | Done — manual check             | Catches drift on the manually-applied firewall/snapshot resources.              |

### 1. Off-Box Dead-Man's-Switch

A systemd timer (`heartbeat-ping`) pings an external healthcheck endpoint every
3 min; the external service alerts when pings stop. Because the ping originates
inside the guest, this catches in-guest hangs as well as a stopped VM — failure
modes that on-box Alertmanager and a control-plane "instance != RUNNING" check
respectively miss. A failed ping leaves a local freshness metric
(`heartbeat_last_ping_timestamp_seconds`) stale, so the internal Mimir stack can
still flag a _degraded_ heartbeat while the host lives.

Files: `hosts/homeserver-gcp/heartbeat.nix`, sops secret `heartbeat_ping_url`.

Status: **done.** A healthchecks.io check (period 3 min, grace 5 min, notification
channel attached) is configured; `heartbeat_ping_url` is in sops; deployed to
`homeserver-gcp`. Verified the check reads `up` with pings flowing.

Acceptance met: total host death is detected off-box without depending on the
VM's own stack. To rotate the endpoint, recreate the check and update
`heartbeat_ping_url` via `sops hosts/homeserver-gcp/secrets/secrets.yaml`.

### 2. Vaultwarden DR Canary Extension

The existing restore canary proved the _repo_ was restorable via a canary file.
It now also restores the consistent Vaultwarden snapshot (`db.sqlite3.backup`)
and runs `PRAGMA integrity_check`, stamping
`vaultwarden_last_restore_test_timestamp_seconds`. A torn or corrupt backup
fails the daily canary instead of being discovered during a real restore.

Files: `hosts/homeserver-gcp/backups.nix` (`restic-restore-canary-b2`).

Status: **done — deployed and verified.** A manual run restored the live
Vaultwarden DB from B2 and passed `integrity_check`, stamping both restore
metrics. Acceptance met: the daily canary fails if the Vaultwarden backup cannot
be restored and opened; freshness metric feeds the existing staleness alert.

### 3. Shielded VM (vTPM + Integrity Monitoring)

`shielded_instance_config` enables vTPM and integrity monitoring on the
instance. **Secure Boot is deliberately off** — stock NixOS produces no signed
boot artifacts, so enabling it would leave the VM unbootable until the image
adopts lanzaboote-style signing.

Files: `infra/main.tf`.

Status: **done — already active, now codified.** GCP had already enabled vTPM +
integrity monitoring on the shielded-capable instance image, so the live state
already matches (`tofu plan` shows no changes and **no VM stop is required**).
The `shielded_instance_config` block makes terraform _enforce_ these values
rather than treat them as an unmanaged provider default, so the drift guard
(#4) will catch any future regression.

Acceptance met: vTPM + integrity monitoring active; Secure Boot left off with a
documented reason. Note: had the values _not_ already matched, applying would
require the VM stopped (e.g. `allow_stopping_for_update` or an explicit
stop → `tofu apply` → start).

### 4. Terraform Drift Guard

`bash scripts/validate.sh tf-drift` runs a read-only `tofu plan
-detailed-exitcode` against live GCP state and reports drift (exit 2). It exists
because `deny-public-ssh` and the snapshot policy carry "apply manually" notes,
so the project can silently diverge from `main`. Manual/local check (needs GCP
credentials via ADC + `infra/terraform.tfvars`), not a CI gate.

The plan is `-target`-scoped to the homeserver host's resources (instance, the
two firewalls, snapshot policy + attachment). This is deliberate: the on-demand
`gcp-builder` normally powers itself off, which nulls its ephemeral external IP
and would otherwise register as perpetual benign drift. The `bootstrap_ssh_public_key`
variable is passed as a placeholder — it is only used at first provisioning and
held under `lifecycle.ignore_changes`, so it produces no diff.

Status: **done — verified clean** (`EXIT=0`, "No changes") against live state.

Acceptance met: drift on the manually-applied resources is detectable on demand.

## Dropped / Parked

- **Billing budgets** — handled via in-app GCP billing tracking; not a repo goal.
- **Secret Manager** — dropped. No metadata-secret reliance exists (the only
  metadata value is a _public_ bootstrap key); sops covers everything real.
  Reopen only if a concrete provider-managed-secret need appears.
- **Cloud Logging** — parked, narrowed. The serial console is already enabled
  and live-reachable via `gcloud`; the only incremental value is _historical_
  serial/audit capture for post-crash forensics. Revisit if a real post-mortem
  ever needs logs from a VM that was unreachable at the time.

## Notes

- `Cloud DNS`, `Cloud KMS`, and the `Service composition DSL` live in
  [`roadmap.md`](roadmap.md) (DSL canonical there; KMS/DNS parked as speculative
  for a tailnet-only host).
- `Automated deploy pipeline` and `Secret rotation ritual` also live in
  [`roadmap.md`](roadmap.md) and are not active homeserver priorities.
- **AdGuard is a fleet-wide DNS SPOF.** If the host dies, tailnet clients using
  it as DNS lose resolution (recovery in `hosts/homeserver-gcp/CLAUDE.md`). This
  reinforces the off-box heartbeat: you want to learn the host is down from
  something that is _not_ behind that DNS.
