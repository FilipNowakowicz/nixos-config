# homeserver-gcp Host

GCP-hosted headless server. Runs the monitoring stack, Tailscale, and Nginx.
No LUKS or impermanence (GCP handles at-rest encryption; state persists on the GCE disk).

Status: **active** — deployed on GCP and accessible via Tailscale.

## Services

- **monitoring stack** — Grafana (sub-path `/grafana/`, Tailscale identity via nginx auth proxy), Loki, Prometheus and Alertmanager
- **Nginx** — reverse proxy, TLS via Tailscale cert
- **SSH** — in-guest firewall exposure limited to `tailscale0`; Terraform also
  adds a high-priority GCP firewall deny for public TCP/22 on the default VPC.
- **Tailscale** — auth key from sops secret `tailscale_auth_key`
- **AdGuard Home** — DNS (TCP/UDP 53) + web UI (HTTPS port 3001 via nginx, internal HTTP on 127.0.0.1:13001), tailscale0 only; state is exposed at `/var/lib/AdGuardHome` and stored by systemd at `/var/lib/private/AdGuardHome`
- **Restic/B2** — off-site backups to Backblaze B2 (`/var/lib/grafana`, staged AdGuard state, and a restore canary)
- **GCE snapshots** — daily 7-day boot disk snapshots for fast provider-local rollback

## Architecture

- **No LUKS** — GCP provides at-rest disk encryption automatically
- **No impermanence** — service state persists at `/var/lib/...` on the stateful GCE disk
- **systemd-boot** — UEFI bootloader (see `hardware-configuration.nix`)
- **50 GB boot disk** — partitioned by `disko.nix` (512 MB ESP + ext4 root taking the rest)

## Disk Layout

`homeserver-gcp` intentionally keeps a root-only data layout: `disko.nix` creates
one 512 MB EFI system partition and one ext4 root filesystem that consumes the
remaining GCE boot disk. There is no `/persist` volume and no reserved data
partition without an owner.

Keep this layout until a concrete operational need appears for isolated quotas
or retention, such as separating Loki, Prometheus, or restic cache churn from the root
filesystem. If that happens, mount only the specific high-churn paths and update
the restore procedure alongside the partition change.

## Provisioning & First Deploy

Runbook: [`.claude/homeserver-gcp/provisioning.md`](../../.claude/homeserver-gcp/provisioning.md)

## Ongoing Updates

```bash
deploy '.#homeserver-gcp'
```

If `deploy-rs` produces no output / appears to hang in a non-interactive
session, fall back to a manual closure deploy: `nix build` the system closure,
`nix copy` it to the host (add `--derivation` if needed), then run
`switch-to-configuration switch` over SSH.

## Automated Deploy Runner

The `Deploy homeserver-gcp` workflow is **disabled in GitHub** until reviewed
and manually verified. Its routine jobs run on GitHub-hosted runners, never on
this host's `github-runner-homeserver-deploy.service`. Keep that self-hosted
runner as a recovery path only; its existing registration and registration-GC
procedures below still apply.

The builder job joins as `tag:ci-builder` using the existing builder secrets
and runs evaluation, shared CI light/smoke validation and all compilation on
`gcp-builder`. It exports the finished activation closure and deploy-rs client
as a short-lived Actions artifact. The deploy job joins as `tag:ci`, imports
that artifact, and deploys with `remoteBuild = false`, `max-jobs = 0` and no
runner builders. There is no compilation on this homeserver or either runner.

Every run requires a current `main` commit with a merged PR whose PR workflow
passed `merge-gate`; absent proof stops deployment. The running system path is
compared to the built closure before activation, so unrelated changes are a
no-op. Deploys are serialized without cancelling an activation. Both push and
manual dispatch use this path; dispatch requires `confirm_target=homeserver-gcp`.
There is no fast validation bypass.

Deployment secrets `TS_OAUTH_DEPLOY_CLIENT_ID`, `TS_OAUTH_DEPLOY_SECRET` and
`HOMESERVER_DEPLOY_SSH_KEY` do not exist yet. Provision them separately before
a live run; never log their values. Review and a successful manual dispatch
(including a repeat proving the no-op path) are required before leaving the
workflow enabled. See [operations](../../docs/operations.md#automated-homeserver-deploy)
for the full prerequisites and live validation checklist.

`magicRollback` and `autoRollback` stay enabled with the existing confirmation
timeout. After activation, the workflow checks the exact system path, drift,
failed units, AdGuard UDP/TCP DNS, Prometheus, Loki and Grafana health. Health
failures are visible failures; a reachable but unhealthy system may require
manual rollback after deploy-rs has confirmed activation.

The recovery runner registration credential remains the sops secret
`github_runner_homeserver_deploy_token`, a fine-grained PAT limited to this
repository with Administration read/write. This host grants its deploy user
broad passwordless sudo: merge access to `main`, deployment credentials and
recovery runner access are root-equivalent. Required reviewers on the
`homeserver-gcp-deploy` environment can add a manual gate.

## Gotchas

- **A "Deploy homeserver-gcp" CI failure can originate from any host, not just
  this one** — the workflow's `validate` job runs `scripts/validate.sh flake-eval`
  and `light`, and `flake/dev.nix`'s `checks` output is
  `deploy-rs.lib.${system}.deployChecks { nodes = ciDeployNodes; }`, which
  builds an activation check for _every_ deploy-rs node (`gcp-builder`, …), not only
  `homeserver-gcp`. A break confined to an unrelated host fails this workflow even though `merge-gate` on the same PR
  passed clean. Read the failing derivation name in the run log before
  assuming the break is homeserver-gcp-specific.
- **sops fails on first boot if the host key was not copied into the installed root** — Tailscale won't join, SSH won't work over Tailscale. Recover via GCE serial console or `gcloud compute ssh` (project SSH keys bypass tailnet-only firewall during recovery), then install the encrypted repo key at `/etc/ssh/ssh_host_ed25519_key` and redeploy.
- **TLS cert is not ACME** — `tailscale-cert.service` fetches it via `tailscale cert`; nginx
  depends on that service via `requires=` so it doesn't start without a cert. A daily
  `tailscale-cert.timer` renews the material and reloads nginx if it is already running.
- **Access is tailnet-only** — `tailscale0` is the only interface that permits inbound SSH/HTTPS.
- **Grafana SSO is Tailscale-aware at nginx** — `/grafana/` now runs through a localhost
  auth helper that resolves the caller with `tailscale whois` and injects Grafana
  auth-proxy headers. Human users land in Grafana as `Viewer` by default unless
  `grafanaTailscaleRoleMap` in `default.nix` promotes specific logins.
- **Grafana break-glass remains local-only** — if the auth helper or role mapping locks
  you out, forward localhost over SSH and use the local Grafana admin account:
  `ssh -L 3000:127.0.0.1:3000 user@homeserver-gcp.example.ts.net`, then open
  `http://127.0.0.1:3000/`.
- **Disk is stateful** — no impermanence or `/persist`. Data survives reboots naturally on root.
- **GCE snapshots are not backups** — use them for fast rollback inside GCP; use restic/B2
  for independent off-site application recovery.
- **Off-site backup via B2** — `services.restic.backups.b2` uses the shared
  `backup.class = "critical"` policy from `modules/nixos/profiles/backup.nix`.
  AdGuard is backed up from `/var/lib/restic-staging/adguardhome` (root-owned
  staging copy) instead of the raw DynamicUser tree. Restore runbook:
  [`.claude/homeserver-gcp/restore-adguard.md`](../../.claude/homeserver-gcp/restore-adguard.md).
- **Restore canary** — `restic-restore-canary-b2.service` restores the latest
  `/var/lib/restic-backup-canary/homeserver-gcp.txt` from B2 (writes
  `restic_last_restore_test_timestamp_seconds`) **and** restores the Grafana
  `grafana.db.backup`, running `PRAGMA integrity_check` on it. A corrupt
  backup fails the daily canary instead of surfacing during a real restore.
- **Full-service restore drill** — `restore-drill-b2.service` (quarterly timer,
  also runnable on demand via `systemctl start restore-drill-b2.service`)
  restores Grafana and AdGuard Home from B2 into a throwaway
  scratch root (`/var/lib/restore-drill/scratch`) and **starts each service
  binary against the restored state in a `PrivateNetwork=true` namespace**,
  asserting each comes up (Grafana `database: ok`, AdGuard
  `/control/status`) before stamping `restore_drill_last_success_timestamp_seconds`.
  It never touches live data and complements the daily canary; `RestoreDrillStale`
  alerts if it has not passed in ~100 days. Defined in `restore-drill.nix`;
  procedure in [`docs/restore-drill.md`](../../docs/restore-drill.md).
- **Alert delivery** — Prometheus/Alertmanager sends fleet alerts to the sops-backed
  `alertmanager_webhook_url`; keep it pointed at an off-host notification
  target. For the alerting/reachability stack itself (`alertmanager`, `prometheus`,
  `prometheus-node-exporter`, `nginx`, `tailscaled`, `heartbeat-ping`),
  `systemd-failure-notify` also posts directly to that webhook through
  `OnFailure=` so a delivery-path unit can report its own failure without
  waiting for the Prometheus evaluator.
- **Off-box heartbeat (dead-man's-switch)** — every alerting component runs _on_
  this host, so a dead VM fires nothing. `heartbeat-ping.timer` pings the
  external URL in sops secret `heartbeat_ping_url` (e.g. a healthchecks.io
  check) every 3 min; the _external_ service alerts when pings stop, catching
  in-guest hangs and total VM death. Defined in `heartbeat.nix`. The secret must
  be populated via `sops` before this host will activate. A successful ping
  stamps `heartbeat_last_ping_timestamp_seconds` so internal alerting can also
  flag a _degraded_ (host-up, ping-failing) heartbeat.
- **AdGuard DNS failure** — AdGuard is the tailnet-wide DNS resolver (set via the
  Tailscale admin DNS nameserver override), so its loss takes resolution down for
  every client. The two failure modes are not equal:
  - **Service crash** — self-heals. The unit carries `Restart=always` /
    `RestartSec=10` (nixpkgs default), so a crashed `adguardhome.service` is back
    within ~10 s with no human action; the gap is seconds. The failed-unit alert
    still fires within 2 min through Prometheus/Alertmanager.
  - **Total VM death** — the only mode needing intervention. The off-box
    heartbeat pages you; recovery is a ~30 s step: Tailscale admin → DNS, remove
    the nameserver override so clients fall back to their default resolver.

  An automatic fallback (a second global nameserver) was deliberately **not**
  added — Tailscale load-balances global nameservers rather than treating extras
  as cold backups, so a public secondary would leak unfiltered (or custom-rule
  breaking) queries during normal operation. The residual single-point-of-failure
  is an accepted, recorded decision documented here.

- **AdGuard web UI** — HTTPS on port 3001 (proxied by nginx using the Tailscale cert). AdGuard itself binds to `127.0.0.1:13001`. Login: `admin`; password material is managed through the sops-backed AdGuard configuration.
- **Deploy runner registration GC** — `services.github-runners.homeserver-deploy`
  only re-registers with GitHub when its NixOS module config or the
  `github_runner_homeserver_deploy_token` secret _changes on disk_ (the
  module's `unconfigure` script `diff`s the new config/token against
  `.nixos-current-config.json`/`.current-token` in the state directory). If
  GitHub garbage-collects or invalidates the registration server-side (e.g.
  after a long idle period) while the local config and token are unchanged,
  that diff sees no change, skips re-registration, and `Runner.Listener`
  starts with stale `.runner`/`.credentials` that GitHub now rejects — the
  unit fails, with a journal entry like "session ... has been deleted" /
  "no longer exists". Recover by clearing the persisted runner state so the
  next start re-registers from scratch:
  ```bash
  ssh user@homeserver-gcp.example.ts.net
  sudo systemctl stop github-runner-homeserver-deploy.service
  sudo find /var/lib/github-runner/homeserver-deploy -mindepth 1 -delete
  sudo systemctl start github-runner-homeserver-deploy.service
  sudo systemctl status github-runner-homeserver-deploy.service --no-pager
  ```
  `find -mindepth 1 -delete` is required instead of `rm -rf .../*` — the
  persisted state (`.runner`, `.credentials`, `.nixos-current-config.json`,
  ...) is all dotfiles a bare glob won't match, and leaving any behind makes
  the unconfigure diff see "unchanged" again and skip re-registration. An
  empty state directory hits the unconfigure script's first-start path, which
  copies `github_runner_homeserver_deploy_token` into the work area; the
  configure script then detects the PAT format and re-registers with
  `--pat`, minting a fresh registration token automatically — no token
  rotation needed for this recovery path.
- **Memory-heavy maintenance oneshots must be contained** — this is a sub-4GB
  host, so any heavy CVE/scan/index maintenance oneshot or timer (the vulnix NVD
  load peaked ~3GB RSS) must **either** run off-host (CI or the `gcp-builder`)
  **or** carry `MemoryMax` + `MemorySwapMax` + a positive `OOMScoreAdjust`. An
  unconstrained unit (`MemoryMax=infinity`) lets a runaway breach RAM and
  swap-storm into a **global** oom-killer (load avg ~47) instead of being
  confined to its own cgroup. **Triage tell:** a cluster of simultaneous,
  unrelated unit failures here (`tailscale-cert` timeout, heartbeat miss,
  Grafana context-deadline) usually traces back to one unconstrained
  memory-heavy unit hogging the box, **not** independent faults — check
  `journalctl -k` for `oom-kill` before chasing each failing unit separately.
  The concrete vulnix instance was fixed by dropping the on-host scan (PR #354);
  the constraint rule generalizes to any future maintenance unit.

## Monitoring decision (#474)

Keep Prometheus (30-day metrics and alert evaluation), Loki, Grafana, Alloy,
Alertmanager, node/blackbox exporters, AdGuard and NixOS. The GitHub recovery
runner stays, and tailnet DNS policy stays unchanged. Mimir, Tempo and the
OpenTelemetry collector/OTLP pipeline were removed: one personal server has no
useful trace producers or need for scalable metrics storage, and the former
metrics backend's rings caused a GCP migration boot crash loop. Reconsider only
for several hosts exceeding one Prometheus's long-term capacity or a self-written
service needing distributed tracing. The registry-wide invariant enforces this.
See [the decision and migration/cleanup procedure](../../docs/observability-stack.md#decision-minimal-personal-server-stack)
for alert continuity, coordinated client/server rollout and manual store cleanup.
