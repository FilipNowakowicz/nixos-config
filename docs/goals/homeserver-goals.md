# Homeserver Goals

Implementation roadmap for `homeserver-gcp`. The reliability work that motivated
this document is complete (see below); this tracks any future homeserver goals.

Current baseline: GCP `e2-medium` in `europe-west2` (`europe-west2-a` zone by
default), reachable through Tailscale only, running Vaultwarden, AdGuard Home,
Nginx with Tailscale-issued TLS, the LGTM observability stack, and Backblaze B2
restic backups (with weekly integrity check + daily restore canary). Daily GCE
boot-disk snapshots and a public-SSH edge deny are managed in `infra/`. The
instance is a Shielded VM (vTPM + integrity monitoring) and an off-box
dead-man's-switch covers total-host-death liveness. Provisioning is automated
through `scripts/deploy-gcp.sh`.

Completed milestones live in the durable docs:

- `README.md` — service surface, dashboards, generated inventory.
- `docs/operations.md` — smoke tests, snapshots, drift guard, validation workflows.
- `docs/security.md` — exposure, Shielded VM, ACL drift detection.
- `docs/backup-validation.md` — restore canary (incl. Vaultwarden DB integrity).
- `docs/restore-drill.md` — backup recovery procedure.
- `hosts/homeserver-gcp/CLAUDE.md` — host-specific operating notes (heartbeat, canary).

## Framing

The host self-monitors well, but **every alerting component (Mimir ruler,
Alertmanager, the ntfy webhook) runs on the host it watches** — if the VM dies,
nothing fires. The provider-native checklist (Cloud Monitoring / Logging /
Secret Manager) was the wrong lens: a tailnet-only host has no public endpoint
for an external uptime probe, and there is no real metadata-secret reliance to
migrate. The reliability work was therefore reshaped around the one genuine gap —
**off-box liveness** — plus small, high-value hardening and verification, all
now shipped (see below).

## Active Goals

None. The last open item (AdGuard DNS SPOF mitigation) was resolved by a recorded
decision on 2026-06-05 — see [Resolved by decision](#resolved-by-decision) below.
The heartbeat-degraded alert shipped 2026-06-05.

## Resolved by decision

### AdGuard DNS SPOF — accepted (2026-06-05)

AdGuard on this host is the tailnet-wide DNS resolver (Tailscale admin nameserver
override), so its loss takes resolution down for every client. We evaluated an
automatic fallback and **deliberately did not add one**; the residual
single-point-of-failure is accepted. Rationale:

- **Crash is already self-healing.** `adguardhome.service` carries
  `Restart=always` / `RestartSec=10` (nixpkgs default), so the common failure —
  the process dying — recovers in ~10 s with no intervention.
- **VM death is already alerted.** The off-box heartbeat dead-man's-switch pages
  on total host death; manual recovery is a ~30 s Tailscale-admin toggle (remove
  the nameserver override → clients fall back to their default resolver).
- **A second global nameserver does not give clean failover.** Tailscale
  load-balances global nameservers and reorders by latency rather than treating
  extras as cold backups ([tailscale#5397]). A plain public secondary would leak
  **unfiltered** queries during normal operation; a public _filtering_ secondary
  would instead break the host's custom `user_rules` allowlist on the share of
  queries it answered. Neither is worth it to cover a rare, already-alerted,
  30-second-recoverable window.

Reopen only if a second always-on tailnet node exists to host a redundant
**filtering** resolver (the only configuration that survives host death without
either unfiltered leakage or allowlist breakage), or if Tailscale gains
backup-only nameserver support.

[tailscale#5397]: https://github.com/tailscale/tailscale/issues/5397

## Completed (now in durable docs)

All four deployed, verified, and merged (#77, #78). Recorded here only as a
pointer to where each now lives.

| Goal                                      | Lives in                                                                 |
| :---------------------------------------- | :----------------------------------------------------------------------- |
| Off-box dead-man's-switch                 | `hosts/homeserver-gcp/heartbeat.nix`; `hosts/homeserver-gcp/CLAUDE.md`   |
| Vaultwarden DR canary extension           | `hosts/homeserver-gcp/backups.nix`; `docs/backup-validation.md`          |
| Shielded VM (vTPM + integrity monitoring) | `infra/main.tf`; `docs/security.md` (§ Shielded VM)                      |
| Terraform drift guard                     | `scripts/validate.sh tf-drift`; `docs/operations.md` (§ Terraform Drift) |

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
