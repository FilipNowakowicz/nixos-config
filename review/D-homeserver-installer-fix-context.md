# Fix Context — homeserver-gcp + installer

Self-contained prompts for a fix agent. Each item: code excerpt, exact issue,
suggested fix, validation command. Ordered by severity. All paths absolute from
repo root `/home/user/nix`.

General validation (run after any change):

```
bash scripts/validate.sh flake-eval
bash scripts/validate.sh host homeserver-gcp
statix check . && deadnix .
```

## Status after PR 62

- `[DONE]` P0-1, P0-4, P0-5, and P1-11 landed.
- `[PARTIAL]` P0-2/P0-3 landed as a configurable Alertmanager webhook path, but
  `homeserver-gcp` still defaults to the null receiver until a secret-backed
  webhook is set.
- `[PARTIAL]` P1-1 landed for HSTS, X-Frame-Options, X-Content-Type-Options,
  and Referrer-Policy; CSP remains open.
- `[DONE]` P1-9 landed as a TLS expiry alert over the existing HTTPS blackbox probes.
- `[DONE]` P1-10 landed by sending nginx access logs to journald and adding a Loki audit source.
- `[OPEN]` P1-2, P1-4, P1-7, P1-8, P2-3, and P3 items remain open.

---

## P0-1 — GCP edge firewall does not block public SSH

File: `infra/main.tf`

```hcl
resource "google_compute_firewall" "tailscale" {
  name        = "${local.name}-tailscale"
  network     = "default"
  allow { protocol = "udp"  ports = ["41641"] }
  target_tags   = [local.name]
  source_ranges = ["0.0.0.0/0"]
}
# VM uses network = "default" with access_config {} (public NAT IP)
```

Issue: the GCP `default` network auto-creates `default-allow-ssh` (TCP/22 from
`0.0.0.0/0`), `default-allow-rdp`, `default-allow-icmp`. Nothing removes them,
so the public NAT IP exposes TCP/22 to the internet. The in-guest nftables rule
is the sole control — defense-in-depth is gone and the "tailnet-only SSH" claim
is false at the edge.

Suggested fix (keep `default` network, add explicit deny + remove default-allow):

```hcl
# Remove GCP's permissive defaults (import or recreate as managed deny).
resource "google_compute_firewall" "deny_all_ingress" {
  name          = "${local.name}-deny-ingress"
  network       = "default"
  priority      = 65000
  direction     = "INGRESS"
  deny { protocol = "all" }
  target_tags   = [local.name]
  source_ranges = ["0.0.0.0/0"]
}
# Tailscale UDP allow must have a LOWER priority number (higher precedence):
resource "google_compute_firewall" "tailscale" {
  # ...existing...
  priority = 900
}
```

Plus, out of band: `gcloud compute firewall-rules delete default-allow-ssh
default-allow-rdp` (or manage them in TF and set them to deny). Better long-term
fix: move the instance into a dedicated VPC/subnet with no auto rules.

Validation:

```
cd infra && tofu validate && tofu plan   # confirm deny rule planned
# Post-apply, from an off-tailnet host:
nc -vz -w5 <NAT_IP> 22   # must time out / be filtered
```

---

## P0-2 — Alertmanager null receiver: no alert is ever delivered

File: `modules/nixos/profiles/observability/alerts.nix:127-142`

```nix
alertmanagerFile = mkYaml "alertmanager.yaml" {
  route = { receiver = "null"; ... };
  receivers = [ { name = "null"; } ];
};
```

Issue: every firing alert (backup stale, unit failed, CVE found, probe failed)
goes to a no-op receiver. Unattended VM = silent failures forever.

Suggested fix (ntfy webhook example; secret via sops template):

```nix
# In a host module, add a sops template producing the alertmanager.yaml with a
# real receiver, then override the tmpfiles copy via lib.mkForce, OR add an
# option to alerts.nix for the receiver. Minimal inline webhook:
receivers = [
  {
    name = "ntfy";
    webhook_configs = [{
      url = "https://ntfy.sh/<your-private-topic>";
      send_resolved = true;
    }];
  }
];
route.receiver = lib.mkForce "ntfy";
```

For SMTP, add `smtp_smarthost`, `smtp_auth_*` from a sops secret. Keep the
secret out of the Nix store: template alertmanager.yaml via
`sops.templates."alertmanager.yaml"` and point the tmpfiles `C+` at
`config.sops.templates."alertmanager.yaml".path`.

Validation:

```
bash scripts/validate.sh host homeserver-gcp
# On host after deploy:
amtool --alertmanager.url=http://127.0.0.1:9009/alertmanager config show
curl -s http://127.0.0.1:9009/alertmanager/api/v2/status | jq .config
```

---

## P0-3 — No Grafana contact point / notification policy

File: `modules/nixos/profiles/observability/default.nix:89-132` (provision block
has datasources + dashboards, no `alerting`).

Issue: neither Mimir Alertmanager nor Grafana unified alerting delivers
anything. Pick one path. If you prefer Grafana-native:

```nix
provision.alerting = {
  contactPoints.settings = {
    apiVersion = 1;
    contactPoints = [{
      name = "ops";
      receivers = [{ uid = "ops-ntfy"; type = "webhook";
        settings.url = "https://ntfy.sh/<topic>"; }];
    }];
  };
  policies.settings = {
    apiVersion = 1;
    policies = [{ receiver = "ops"; }];
  };
};
```

Recommendation: implement P0-2 (Mimir Alertmanager) since the rules already
live there; do NOT also build Grafana alerting unless you migrate the rules.

Validation: `bash scripts/validate.sh host homeserver-gcp`; on host check
`/grafana/alerting/notifications`.

---

## P0-4 — Backup success metric stamped regardless of real success

File: `hosts/homeserver-gcp/backups.nix:4-12`

```nix
restic-backups-b2.serviceConfig.ExecStartPost = pkgs.writeShellScript "restic-backup-metrics" ''
  ...
  echo "restic_last_backup_timestamp_seconds $(date +%s)"
  ...
'';
```

Issue: `ExecStartPost` of a multi-`ExecStart` restic unit can run after a
partial/prune-failed backup and stamp a false-fresh timestamp; the
`ResticBackupStale` alert and status badge then read green on a broken backup.

Suggested fix — derive the metric from the repository, not the unit:

```nix
restic-backups-b2.serviceConfig.ExecStartPost =
  pkgs.writeShellScript "restic-backup-metrics" ''
    set -euo pipefail
    ts=$(${pkgs.restic}/bin/restic snapshots --json --latest 1 \
      --repository-file=${config.sops.secrets.restic_repository.path} \
      | ${pkgs.jq}/bin/jq -r 'max_by(.time).time
        | sub("\\.[0-9]+";"") | sub("([+-][0-9:]+|Z)$";"Z")
        | fromdateiso8601')
    tmp=/var/lib/node-exporter-textfiles/restic_backup.prom.tmp
    printf '# TYPE restic_last_backup_timestamp_seconds gauge\nrestic_last_backup_timestamp_seconds %s\n' "$ts" > "$tmp"
    mv "$tmp" /var/lib/node-exporter-textfiles/restic_backup.prom
  '';
```

(Needs `RESTIC_PASSWORD_FILE` + `EnvironmentFile=b2_credentials` on the
restic-backups-b2 unit; the NixOS restic module already sets these for the
backup run, but `ExecStartPost` shares the unit env, so it is available.)
Gate on `$SERVICE_RESULT` if you keep the date-stamp approach:

```nix
ExecStartPost = "+${script}";  # and inside: [ "$SERVICE_RESULT" = success ] || exit 0
```

Validation:

```
bash scripts/validate.sh host homeserver-gcp
# On host: simulate failure (bad repo) and confirm metric NOT advanced:
systemctl start restic-backups-b2; cat /var/lib/node-exporter-textfiles/restic_backup.prom
```

---

## P0-5 — Grafana SQLite not snapshot-consistent in backup

File: `hosts/homeserver-gcp/backups.nix:45-54` (`/var/lib/grafana` is backed up
raw while grafana.service runs).

Issue: restic may capture `grafana.db` mid-write (WAL) → torn restore.

Suggested fix — pre-backup hook doing a consistent copy:

```nix
services.restic.backups.b2.backupPrepareCommand = ''
  ${pkgs.sqlite}/bin/sqlite3 /var/lib/grafana/grafana.db \
    "VACUUM INTO '/var/lib/grafana/grafana.db.backup'"
'';
# add /var/lib/grafana/grafana.db.backup to paths; optionally exclude the live db.
```

Validation: `bash scripts/validate.sh host homeserver-gcp`; on host run the
backup and confirm `grafana.db.backup` is a valid sqlite (`sqlite3 ... 'pragma
integrity_check'`).

---

## P1-1 — Missing security response headers

File: `hosts/homeserver-gcp/nginx.nix:46-50` (`virtualHosts.<fqdn>` has no
server-level `extraConfig` with headers; `recommendedTlsSettings` adds no HSTS).

Issue: no HSTS/CSP/X-Frame-Options on a Vaultwarden-serving proxy; and any
`add_header` inside a location silently drops inherited headers.

Suggested fix:

```nix
virtualHosts.${cfg.fqdn} = {
  # ...
  extraConfig = ''
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
  '';
  # ...
};
```

Then in every location that already sets `add_header Cache-Control ...`
(the `/home/*` blocks), re-add the security headers too (nginx drops inherited
ones once any add_header is present in the block).

Validation:

```
bash scripts/validate.sh host homeserver-gcp
# On host: curl -kI https://<fqdn>/ | grep -i strict-transport
#          curl -kI https://<fqdn>/home/status.json | grep -i x-frame
```

---

## P1-2 — Vaultwarden /admin posture implicit

File: `hosts/homeserver-gcp/default.nix:167-175` and `nginx.nix:52`.

Issue: `/admin` reachability depends on upstream default (no `ADMIN_TOKEN`).
Make explicit.

Suggested fix (block it at nginx):

```nix
# in nginx.nix locations:
"= /admin" = { return = "404"; };
"^~ /admin/" = { return = "404"; };
```

Or set an `ADMIN_TOKEN` from sops if you want admin access. Document the choice.

Validation: `curl -kI https://<fqdn>/admin` returns 404.

---

## P1-4 — AdGuard config is imperative and blocklists absent

File: `hosts/homeserver-gcp/adguard.nix:1-21`

```nix
services.adguardhome = { mutableSettings = true; settings.dns = { ... }; };
```

Issue: blocklists, admin user, client rules live only on disk; not reproducible,
not in git, lost on baked-image rebuild.

Suggested fix:

```nix
services.adguardhome = {
  mutableSettings = false;
  settings = {
    users = [{ name = "admin"; password = "$2y$..."; }]; # bcrypt via sops template
    dns = { /* existing */ };
    filters = [
      { enabled = true; name = "AdGuard DNS filter";
        url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt"; id = 1; }
      { enabled = true; name = "OISD Big";
        url = "https://big.oisd.nl"; id = 2; }
      { enabled = true; name = "Hagezi Multi Pro";
        url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt"; id = 3; }
    ];
  };
};
```

Source the admin password hash from a sops template (don't hardcode). Note:
`mutableSettings = false` overwrites web-UI edits on every deploy — intended.

Validation: `bash scripts/validate.sh host homeserver-gcp`; on host confirm
`/var/lib/private/AdGuardHome/AdGuardHome.yaml` matches declared filters after
restart.

---

## P1-7 — DynamicUser backup/restore UID mismatch (AdGuard)

File: `hosts/homeserver-gcp/backups.nix:49` (`/var/lib/private/AdGuardHome`).

Issue: restored files carry the recorded dynamic UID, which won't match the next
boot's DynamicUser allocation → AdGuard may fail or recreate state.

Suggested fix — back up a neutral export instead of the private tree:

```nix
services.restic.backups.b2.backupPrepareCommand = ''
  install -d -m700 /var/backup/adguard
  cp -a /var/lib/private/AdGuardHome/AdGuardHome.yaml /var/backup/adguard/ || true
'';
# paths: replace /var/lib/private/AdGuardHome with /var/backup/adguard
```

Document in the restore runbook that AdGuard state is restored by dropping the
yaml back and letting systemd re-own.

Validation: `bash scripts/validate.sh host homeserver-gcp`.

---

## P1-8 — No restore runbook

File: `hosts/homeserver-gcp/CLAUDE.md` (has backup creation, no restore).

Fix: add a `## Restore` section:

```
1. Provision fresh VM + install NixOS (deploy-gcp.sh).
2. Ensure sops secrets decrypt (host key present).
3. restic restore latest --target / \
     --repository-file <restic_repository.path> \
     (RESTIC_PASSWORD_FILE + B2 env from sops)
4. Restore caveats: Grafana grafana.db.backup -> grafana.db (stop grafana first);
   AdGuard yaml dropped into /var/lib/private/AdGuardHome, let systemd re-own.
5. systemctl restart vaultwarden grafana adguardhome.
```

No build validation; review for accuracy. Optionally add a restore-test timer
(P3-3).

---

## P1-9 — No TLS cert-expiry monitoring; cert failure = hard nginx down

Files: `hosts/homeserver-gcp/tailscale-cert.nix`, `grafana.nix:48-57`
(nginx `requires=tailscale-cert.service`).

Fix — add a TLS-expiry blackbox probe (or textfile metric):

```nix
# blackbox probe using ssl module in default.nix observability.collectors.blackbox.probes:
tls-expiry = {
  url = "https://${tailnetFQDN}/";
  # requires a blackbox "tcp"/"http" module exporting probe_ssl_earliest_cert_expiry
  expectedStatusCodes = [ 200 301 302 403 ];
};
```

Then alert on `probe_ssl_earliest_cert_expiry - time() < 7*86400`. The blackbox
exporter already exports `probe_ssl_earliest_cert_expiry` for HTTPS targets, so
just add the alert rule in `alerts.nix`:

```nix
{ alert = "TLSCertExpiringSoon";
  expr = "probe_ssl_earliest_cert_expiry - time() < 7*86400";
  for = "1h"; labels.severity = "critical";
  annotations.summary = "TLS cert for {{ $labels.instance }} expires in <7d"; }
```

Validation: `bash scripts/validate.sh host homeserver-gcp`; on host
`curl -s 'http://127.0.0.1:9090/api/v1/query?query=probe_ssl_earliest_cert_expiry'`.

---

## P1-10 — nginx access logs not shipped / not structured

File: `hosts/homeserver-gcp/nginx.nix` (no log_format; not in audit collector).

Fix — log via journald and add an audit source:

```nix
# nginx.nix:
services.nginx.appendHttpConfig = ''
  log_format json_combined escape=json '{"time":"$time_iso8601","remote":"$remote_addr",'
    '"method":"$request_method","uri":"$request_uri","status":$status,'
    '"ua":"$http_user_agent","rt":$request_time}';
  access_log syslog:server=unix:/dev/log,nohostname json_combined;
'';
# default.nix observability.collectors.audit.extraSources:
nginx = { matches = "SYSLOG_IDENTIFIER=nginx"; eventType = "http"; scope = "edge-access"; formatAsJson = true; };
```

Validation: `bash scripts/validate.sh host homeserver-gcp`; on host
`journalctl -t nginx -n5`, then query Loki for `{audit_source="nginx"}`.

---

## P1-11 — Installer SSH hardening gap

File: `hosts/installer/default.nix:9-16`

```nix
networking.firewall.allowedTCPPorts = [ 22 ];
services.openssh = { enable = true; settings.PermitRootLogin = "yes"; };
users.users.root.openssh.authorizedKeys.keys = import ../../lib/pubkeys.nix;
```

Issue: no `PasswordAuthentication = false`, no fail2ban, no hardening profile;
PermitRootLogin yes on a globally-open port.

Suggested fix:

```nix
services.openssh = {
  enable = true;
  settings = {
    PermitRootLogin = "prohibit-password";
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
  };
};
```

(Keeps key-based root login for nixos-anywhere while killing password paths.)

Validation: `bash scripts/validate.sh host installer` (or `nix build
.#nixosConfigurations.installer.config.system.build.toplevel` if no validate
target); confirm sshd_config has `PasswordAuthentication no`.

---

## P2-3 — Status page leaks tailnet topology unauthenticated

File: `hosts/homeserver-gcp/status-page.nix:225-291`, `nginx.nix:114-140`.

Fix: drop `tailnetDevices` detail and failed-unit _names_ from the public JSON
(emit counts only), or gate `/home/*` behind the grafana-style auth_request.
Minimal change — replace device list with a count in the jq `'{...}'` builder.

Validation: `bash scripts/validate.sh host homeserver-gcp`; on host
`curl -s http://127.0.0.1/home/status.json | jq '.tailnet'` shows no hostnames.

---

## P3 (future) — see findings file P3-1..P3-9.

Highest value: P3-1 (alert delivery, = P0-2), then P3-2 (cert expiry),
P3-3 (restore test), P3-4 (declarative AdGuard), P3-6 (GCP edge firewall).
