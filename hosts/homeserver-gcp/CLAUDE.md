# homeserver-gcp Host

GCP-hosted headless server. Runs the monitoring stack, Tailscale, and Nginx.
No LUKS or impermanence (GCP handles at-rest encryption; state persists on the GCE disk).

Status: **active** — deployed on GCP and accessible via Tailscale.

## Services

- **monitoring stack** — Grafana (sub-path `/grafana/`, Tailscale identity via nginx auth proxy; dashboards `overview`, with `main` detail in a collapsed row, and `security-events`), Loki, Prometheus and Alertmanager
- **Nginx** — reverse proxy, TLS via Tailscale cert; `/` redirects to `/grafana/`
- **SSH** — in-guest firewall exposure limited to `tailscale0`; Terraform also
  adds a high-priority GCP firewall deny for public TCP/22 on the default VPC.
- **Tailscale** — auth key from sops secret `tailscale_auth_key`; also an
  opt-in exit node (see [Exit node](#exit-node))
- **ntfy** — the fleet's notification server, tailnet-only on HTTPS port 2586 (see [ntfy](#ntfy))
- **AdGuard Home** — DNS (TCP/UDP 53) + web UI (HTTPS port 3001 via nginx, internal HTTP on 127.0.0.1:13001), tailscale0 only; state is exposed at `/var/lib/AdGuardHome` and stored by systemd at `/var/lib/private/AdGuardHome`
- **Attic binary cache** — `atticd` behind nginx on HTTPS port 8443
  (tailnet-only), chunks in GCS; see [Binary cache](#binary-cache)
- **Restic/B2** — off-site backups to Backblaze B2 (`/var/lib/grafana`, staged AdGuard state, and a restore canary)
- **GCE snapshots** — daily 7-day boot disk snapshots for fast provider-local rollback

## Architecture

- **No LUKS** — GCP provides at-rest disk encryption automatically
- **No impermanence** — service state persists at `/var/lib/...` on the stateful GCE disk
- **systemd-boot** — UEFI bootloader (see `modules/nixos/hardware/gce-vm.nix`;
  the shared GCE baseline is `modules/nixos/profiles/gce-server.nix`)
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

## Exit node

This host is a Tailscale exit node that is **off by default**: no device's
traffic goes through it until that device picks it. It is driven by
`tailscale.exitNodeCanProvide = true` in `lib/hosts.nix`, which makes
`gce-server.nix` enable IP forwarding (`useRoutingFeatures = "server"`) and run
`tailscale set --advertise-exit-node`, and makes the generated ACL auto-approve
`tag:server` as an exit node (applied by the `tailscale-acl-drift` workflow on
merge).

- **Who can use it** — only sources granted `autogroup:internet` in
  `flake.nix`'s `tailnetAcl`: devices logged in as an admin user,
  `tag:workstation`, and `tag:phone` (the phone, its main user).
  `tag:ci`, `tag:ci-builder` and `tag:builder` are not offered it.
- **Turn it on** — in the Tailscale app, pick _Exit node → homeserver-gcp_ (on
  Linux: `tailscale set --exit-node=homeserver-gcp`). Turn it off the same way
  (`tailscale set --exit-node=`). Never set it declaratively: the invariants
  reject `exitNodeUse` in the registry and `--exit-node` in any host's flags.
  On `main` it would also compete with Mullvad's routing.
- **DNS** — clients keep the tailnet DNS (MagicDNS, global nameserver
  override → AdGuard here), so filtering still applies on the exit node; the
  resolver is reached over the tailnet, not through the exit path.
- **Check** — `tailscale status` on a client lists this host with
  `offers exit node`; `tailscale exit-node list` shows it as available, and
  `tailscale status --json | jq .ExitNodeStatus` stays `null` until picked.
- **Egress** — exit traffic is NATed to the VM's own address by Tailscale, so
  GCE needs no `canIpForward`; it leaves with the VM's external IP.

## ntfy

Self-hosted ntfy (#630, `ntfy.nix`, shared facts in `lib/ntfy.nix`) carries
every notification that starts inside the tailnet, on one topic, `fleet`.

- **Reach** — ntfy listens on `127.0.0.1:12586`; nginx serves it with the
  Tailscale cert at `https://homeserver-gcp.tail90fc7a.ts.net:2586`, opened on
  `tailscale0` only. The ACL admits port 2586 from `tag:workstation`,
  `tag:phone` and `tag:builder` (plus admin devices through break-glass); the
  firewall/`acceptFrom` invariant and the reviewed-grants list keep them tied.
- **Auth** — anonymous access is denied. Users are provisioned from sops on
  every start: `phone` (password `ntfy_phone_password`, read-only), `main`
  (token, read-write), `builder` and `homeserver` (tokens, write-only).
  Rotate a token with `bash scripts/rotate-secret.sh ntfy-token <name>`, which
  writes every copy (homeserver, `home/users/user/secrets/ntfy.yaml`,
  `hosts/main/secrets/secrets.yaml`).
- **State** — the message cache keeps 168 h, for clients offline for a few
  days. State lives in `/var/lib/private/ntfy-sh` and is not backed up: users
  are declarative, and the cache holds only delivered notifications.
- **Senders and sources** — each message carries a `source-*` tag and an
  emoji tag (`lib/ntfy.nix`), which `main` maps to the app name and icon:
  homeserver (Alertmanager, failed units), remote builder (`builder-prebuild`),
  backups and system (`main`'s failed units), phone backup
  (`phone-backup-stale-check`), on-worker (jobs) and deploys (GitHub).
- **Alerts** — the `fleet-alert` template turns the Alertmanager payload into
  `[FIRING] <alert> on <host>`, the summaries as body, and priority from
  severity: critical 5, warning 3, resolved 2.
- **Fallback** — when this host, nginx or ntfy is down, nothing can report
  through it. The public ntfy.sh topic (`ntfy_fallback_url`, `topic_url` in
  `ntfy.yaml`, GitHub secret `NTFY_TOPIC_URL`) keeps this host's own
  delivery-path failures, GitHub deploy failures and the healthchecks.io
  heartbeat integration. `main` subscribes to both. Rotate the topic with
  `bash scripts/rotate-secret.sh ntfy-fallback`, then update the GitHub secret
  and the healthchecks.io integration.
- **Test** — from `main`:
  `curl -u ":$(sops -d --extract '["token"]' home/users/user/secrets/ntfy.yaml)" -H 'Title: Test' -H 'Priority: high' -H 'Tags: source-homeserver' -d hello https://homeserver-gcp.tail90fc7a.ts.net:2586/fleet`.
  For a formatted alert, run `amtool --alertmanager.url=http://127.0.0.1:9093 alert add NtfyTest severity=warning host=homeserver-gcp --annotation=summary=test` on this host
  and remove it with `amtool silence` or let it expire.

### Subscribe the phone

Not automated. The phone must be on the tailnet as `tag:phone`.

1. Install the ntfy app (F-Droid or Play Store).
2. Settings → Users → Add user: service URL
   `https://homeserver-gcp.tail90fc7a.ts.net:2586`, username `phone`, password
   from `sops -d --extract '["ntfy_phone_password"]' hosts/homeserver-gcp/secrets/secrets.yaml`.
3. Add subscription → topic `fleet`, tick "Use another server" and enter the
   same URL. The app keeps a connection open to a self-hosted server (instant
   delivery); allow it to run in the background.
4. Add subscription → topic name from the fallback URL
   (`sops -d --extract '["topic_url"]' home/users/user/secrets/ntfy.yaml`, the
   part after `https://ntfy.sh/`) on the default ntfy.sh server.

The app label stays "ntfy" on Android; titles and emoji tags identify the
source.

## Binary cache

The `fleet` attic cache (#631, `attic.nix`) holds what `gcp-builder` builds,
so `main`, this host and the builder can substitute it while the builder is
off.

- **Path** — the builder's `attic-watch-store` pushes to
  `https://homeserver-gcp.<tailnet>:8443/`; nginx streams to `atticd` on
  `127.0.0.1:18180`; attic stores zstd chunks in the GCS bucket
  `nixos-config-attic-8c41e7` (`infra/cache.tf`) through the S3 XML API with
  an HMAC key. Consumers read `https://…:8443/fleet`
  (`modules/nixos/profiles/fleet-cache.nix`).
- **Reach** — tailscale0 port 8443 only, granted to `tag:workstation` and
  `tag:builder` in `lib/hosts.nix`. The cache is public inside that boundary
  (no pull tokens); pushing needs a token. CI runners have no grant: CI builds
  on the builder, which substitutes from the cache itself.
- **Never a dependency** — the cache has priority 41, after cache.nixos.org,
  and consumers set `connect-timeout = 5` and `fallback = true`, so a down
  host costs one short timeout before Nix disables the substituter for that
  session. The builder's watcher just restarts.
- **Bounds** — objects neither pushed nor fetched for 30 days are dropped by
  attic's 12-hourly GC, which deletes the orphaned chunks from GCS. The bucket
  has no versioning or soft delete and aborts multipart uploads after a day.
  Local state is only the sqlite database at `/var/lib/private/atticd`.
  `atticd` runs at `MemoryHigh=384M`/`MemoryMax=640M`, low CPU and IO weight.
- **Bootstrap** — `atticd-init` (timer: 30 s after boot or switch, then
  every 12 h) creates the cache with the sops signing key and re-asserts its
  settings. It fails if the cache signs with anything but
  `lib/binary-cache.nix`'s `fleetCache.publicKey`. It is not in the switch
  path, so it cannot fail a deploy.
- **Secrets** — `secrets/attic.yaml`: `attic_signing_key`,
  `attic_jwt_rs256_secret_base64`, `attic_gcs_access_key_id`,
  `attic_gcs_secret_access_key`. The builder's push token (`push_token`,
  valid until about 2028-11-28) is operator-only in
  `home/users/user/secrets/attic.yaml`; see the builder's
  [runbook](../gcp-builder/CLAUDE.md#binary-cache-push).
- **No backup** — the cache is rebuildable. If the database is lost, empty
  the bucket (`gcloud storage rm "gs://nixos-config-attic-8c41e7/**"`), because
  chunks the new database does not know are never collected; `atticd-init`
  re-creates the cache with the same key.
- **Check** — `curl -fsS https://homeserver-gcp.<tailnet>:8443/fleet/nix-cache-info`;
  the blackbox `attic-cache` probe does the same, and
  `nix path-info --store https://homeserver-gcp.<tailnet>:8443/fleet <path>`
  finds a pushed path.

Rotations:

- **HMAC key** — create a new one and pipe it into sops without printing it,
  merge, then deactivate and delete the old key:

  ```bash
  json=$(gcloud storage hmac create attic-cache@<project>.iam.gserviceaccount.com --format=json)
  jq -j .metadata.accessId <<<"$json" | bash scripts/rotate-secret.sh set hosts/homeserver-gcp/secrets/attic.yaml attic_gcs_access_key_id
  jq -j .secret <<<"$json" | bash scripts/rotate-secret.sh set hosts/homeserver-gcp/secrets/attic.yaml attic_gcs_secret_access_key
  unset json
  ```

- **Push token** — after the JWT secret changes or before the token expires,
  mint a new one against `/etc/atticd/admin.toml` (`atticadm make-token --sub
gcp-builder --validity 2y --pull fleet --push fleet`, with the JWT secret in
  `ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64`), pipe it into
  `rotate-secret.sh set home/users/user/secrets/attic.yaml push_token`, and
  reseed the builder. Rotating `attic_jwt_rs256_secret_base64` invalidates
  every token.

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

## Automated Deploy

The `Deploy homeserver-gcp` workflow is **active**: every merge to `main` that
touches this host's closure deploys it automatically. All of its jobs run on
GitHub-hosted runners; this host runs no GitHub runner (the self-hosted
recovery runner was removed in #627).

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
`HOMESERVER_DEPLOY_SSH_KEY` live in the `homeserver-gcp-deploy` environment;
never log their values. See [operations](../../docs/operations.md#automated-homeserver-deploy)
for the full prerequisites and live validation checklist.

`magicRollback` and `autoRollback` stay enabled with the existing confirmation
timeout. After activation, the workflow checks the exact system path, drift,
failed units, AdGuard UDP/TCP DNS, Prometheus, Loki and Grafana health. Health
failures are visible failures; a reachable but unhealthy system may require
manual rollback after deploy-rs has confirmed activation.

This host grants its deploy user broad passwordless sudo: merge access to
`main` and the deployment credentials are root-equivalent. Required reviewers
on the `homeserver-gcp-deploy` environment can add a manual gate.

## Out-of-band Recovery

SSH is tailnet-only (in-guest firewall plus the `deny-public-ssh` GCP rule), so
with Tailscale down the host looks unreachable. The remaining channels are:

1. **GCE serial console** — `gcloud compute instances get-serial-port-output`
   for read-only diagnosis; interactive login needs the sops-managed console
   password. There is no guest agent, so metadata startup scripts do not run.
2. **Boot-disk surgery via `gcp-builder`** — stop this VM, detach its boot disk,
   attach it to a started `gcp-builder`, mount the ext4 root by device path
   (both disks carry the same filesystem label), fix it, reattach it with
   `--boot --device-name=persistent-disk-0`, and start the VM.

## Gotchas

- **A "Deploy homeserver-gcp" CI failure can originate from any host, not just
  this one** — the workflow's `validate` job runs `scripts/validate.sh flake-eval`
  and `light`, and `flake/dev.nix`'s `checks` output is
  `deploy-rs.lib.${system}.deployChecks { nodes = ciDeployNodes; }`, which
  builds an activation check for _every_ deploy-rs node (`gcp-builder`, …), not only
  `homeserver-gcp`. A break confined to an unrelated host fails this workflow even though `merge-gate` on the same PR
  passed clean. Read the failing derivation name in the run log before
  assuming the break is homeserver-gcp-specific.
- **sops fails on first boot if the host key was not copied into the installed root** — Tailscale won't join, SSH won't work over Tailscale. Recover through the [out-of-band channels](#out-of-band-recovery), then install the encrypted repo key at `/etc/ssh/ssh_host_ed25519_key` and redeploy.
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
- **Alert delivery** — Alertmanager posts fleet alerts to the local ntfy
  server (loopback, bearer token `ntfy_token_homeserver`), whose `fleet-alert`
  template formats them (see [ntfy](#ntfy)). `systemd-failure-notify` posts
  `prometheus` and `prometheus-node-exporter` failures there too, and falls
  back to the public topic if ntfy refuses. The units ntfy delivery depends on
  (`alertmanager`, `heartbeat-ping`, `nginx`, `ntfy-sh`, `tailscaled`) post
  straight to the public ntfy.sh fallback topic in `ntfy_fallback_url`, so a
  delivery-path unit can report its own failure. The
  `alertDeliveryHasFailedUnitFallback` invariant pins that list.
- **Off-box heartbeat (dead-man's-switch)** — every alerting component runs _on_
  this host, so a dead VM fires nothing. `heartbeat-ping.timer` pings the
  external URL in sops secret `heartbeat_ping_url` (e.g. a healthchecks.io
  check) every 3 min; the _external_ service alerts when pings stop, catching
  in-guest hangs and total VM death. Defined in `heartbeat.nix`. The secret must
  be populated via `sops` before this host will activate. A successful ping
  stamps `heartbeat_last_ping_timestamp_seconds` so internal alerting can also
  flag a _degraded_ (host-up, ping-failing) heartbeat.
- **Alert pipeline dead-man's-switch (Watchdog)** — the heartbeat proves the VM
  is up, not that alerts can leave it. The always-firing `Watchdog` rule is
  routed only to the `watchdog` receiver, which Alertmanager posts about every
  minute to the URL in sops secret `alertmanager_watchdog_url`: a _second_
  healthchecks.io check (period 5 min, grace 5 min), separate from the
  heartbeat one. Until it is set the secret holds a loopback placeholder
  (`http://127.0.0.1:9/...`), so sends fail harmlessly in Alertmanager's log.
  Set the real ping URL with
  `bash scripts/rotate-secret.sh set hosts/homeserver-gcp/secrets/secrets.yaml alertmanager_watchdog_url`
  (value on stdin, e.g. `printf '%s' "$URL" |`), then merge to deploy.
- **Blind-spot alerts (#628)** — `DnsProbeFailed` resolves a real external
  name through AdGuard's tailnet address (blackbox `dns-adguard` job), so a hung
  AdGuard or failing upstreams page, not only a failed unit. `ScrapeTargetDown`
  covers `up == 0`, including the stack's own Alertmanager, Grafana, Loki, Alloy
  and blackbox exporter. `GcpBuilderLeftRunning` fires when gcp-builder has been
  online in this host's `tailscale status` for 4 h (`tailnet-presence.timer`
  writes `tailscale_peer_online`); it needs no GCP credentials.
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
Alertmanager, node/blackbox exporters, AdGuard and NixOS. Tailnet DNS policy
stays unchanged. Mimir, Tempo and the
OpenTelemetry collector/OTLP pipeline were removed: one personal server has no
useful trace producers or need for scalable metrics storage, and the former
metrics backend's rings caused a GCP migration boot crash loop. Reconsider only
for several hosts exceeding one Prometheus's long-term capacity or a self-written
service needing distributed tracing. The registry-wide invariant enforces this.
See [the decision and migration/cleanup procedure](../../docs/observability-stack.md#decision-minimal-personal-server-stack)
for alert continuity, coordinated client/server rollout and manual store cleanup.
