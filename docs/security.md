# Security Model

This document captures the current security-relevant design. It is descriptive,
not a substitute for reviewing the NixOS modules before deploying sensitive
changes.

## Secrets

Secrets are managed by `sops-nix` with age recipients configured in `.sops.yaml`.

Current recipient groups:

| Group                  | Purpose                                                  |
| :--------------------- | :------------------------------------------------------- |
| `&user`                | Personal operator key; root secret for all repo secrets. |
| `&main_host`           | `main` SSH-host-derived age identity.                    |
| `&mac_host`            | `mac` SSH-host-derived age identity.                     |
| `&homeserver_gcp_host` | `homeserver-gcp` SSH-host-derived age identity.          |

Host behavior:

- `main` and `homeserver-gcp` use SSH-host-derived age identities through `sops.age.sshKeyPaths`.
- `mac` also uses a pre-baked encrypted SSH host key committed under
  `hosts/mac/secrets/`; sops derives `&mac_host` from the persisted private key
  on boot.
- `homeserver-gcp` uses a pre-baked encrypted SSH host key committed to the repo. During `scripts/deploy-gcp.sh`, the key is decrypted only into a local temporary directory, installed on the bootstrap VM over SSH, verified with `ssh-keyscan`, and copied into the installed NixOS root with `nixos-anywhere --extra-files`; OpenTofu never receives the private key as a variable, metadata value, output, or state value. The temporary local copy is removed by the deploy script exit trap.
- Planned Home Manager user-secret backups under `home/users/user/secrets/` are encrypted only to `&user`; hosts do not decrypt them automatically.
- `boot.initrd.secrets` must point only at sops-managed `/run/secrets/*` paths; this is enforced by a native NixOS assertion in the shared SOPS profile.
- Intentional plaintext exceptions must be narrow entries in `.plaintext-secrets-allowlist`.

`&user` is the root secret for this repository. It is intentionally broad so the
operator can recover and maintain every encrypted file from one personal age
identity, but exposing that private key exposes every repo secret reachable
through `.sops.yaml`. If the personal age key is copied to an untrusted machine,
included in a public artifact, logged, backed up to an untrusted location, or
otherwise suspected compromised, rotate the personal key and re-encrypt all repo
secrets. Also rotate the underlying credentials that were decryptable by the old
key unless the exposure window can be ruled out.

Because `&user` is the root secret, _losing_ it (not just exposing it) is its own
single point of failure: the key is copied into the B2 backup, but reading that
backup needs the restic password, which is itself encrypted to the key. An
out-of-band escrow copy breaks that circular dependency. See
[`docs/key-escrow.md`](key-escrow.md) for the escrow locations, verification, and
the blank-machine recovery procedure.

Structured SOPS files under `home/users/user/secrets/` are accepted even though
their cleartext keys disclose provider and account shape, such as which tools
have restorable auth state and the visible GitHub hostname/username nesting in
the GitHub CLI backup. Token values must still be encrypted, and the repository
check rejects plaintext JSON/YAML auth backups in that directory.

## Host Key Rotation

Rotating a host identity requires both the host material and the sops recipient
set to change together.

For SSH-host-derived identities:

1. Generate or capture the new SSH host public key.
2. Convert it with `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub`.
3. Update the relevant recipient in `.sops.yaml`.
4. Run `sops updatekeys <secret-file>` for every affected secret file.
5. Deploy only after the target can access the new private key at boot.

For `homeserver-gcp`, rotate the dedicated age key by regenerating the encrypted
key pair, updating `&homeserver_gcp_host` in `.sops.yaml`, and re-encrypting
every file under `hosts/homeserver-gcp/secrets/` in the same change. Because
older bootstrap flows put the host private key in GCE instance metadata and
local OpenTofu state, rotation should also verify that `ssh-host-key-b64` is
absent from instance metadata, ignored `infra/*.tfstate*`, logs, and backups; if
that cannot be proven, also rotate credentials decryptable by
`&homeserver_gcp_host`, including Tailscale, Grafana, restic/B2, and service
password material.

## Secret Rotation Ritual

Rotation of an individual sops _value_ (as opposed to a host identity, above) is
mostly mechanical, and the mechanical part is where this repo has been bitten:
`sops --set` fed through `$(cat key)` strips a value's trailing newline so
OpenSSH rejects the key, and treefmt then reformats `secrets.yaml` and reddens
the lint gate. `scripts/rotate-secret.sh` bottles that envelope — it sets values
byte-for-byte, runs `nix fmt` on the touched file, and re-verifies the stored
value round-trips before returning. Run it inside `nix develop`.

What the helper can generate locally vs. what you must obtain out of band splits
the inventory into three kinds:

- **self** — value generated locally; the helper rotates it end to end.
- **provider** — value issued by an external console; you mint it, then pipe it
  through `rotate-secret.sh set` for the byte-safe write + verify.
- **capture** — value is the output of an interactive CLI login; re-run the
  login, then capture the file into sops (no meaningful automation).

### Inventory

| Secret                                                               | Owner host(s)                   | Kind     | Rotate with                                                                    |
| :------------------------------------------------------------------- | :------------------------------ | :------- | :----------------------------------------------------------------------------- |
| `user_password` / `root_password`                                    | all / `mac`                     | self     | `rotate-secret.sh password <file> <key>`                                       |
| `observability_ingest_password` (+`_htpasswd`)                       | `main`,`mac` / `homeserver-gcp` | self     | `rotate-secret.sh observability` (rotates the pair across all three)           |
| `adguard_admin_password`                                             | `homeserver-gcp`                | self     | `rotate-secret.sh random`                                                      |
| `grafana_admin_password`                                             | `homeserver-gcp`                | self     | `rotate-secret.sh random` — **but** set it in Grafana too; see caveats         |
| `grafana_secret_key`                                                 | `homeserver-gcp`                | self     | `rotate-secret.sh random` — **caveat:** re-encrypts datasource secrets         |
| `restic_password`                                                    | `main`,`homeserver-gcp`         | self     | `restic key add/remove` first, _then_ `rotate-secret.sh set`; see caveats      |
| `initrd_ssh_host_ed25519_key`                                        | `main`                          | self     | `rotate-secret.sh sshkey <file> <key>`                                         |
| `homeserver_selfdeploy_ssh_key`                                      | `homeserver-gcp`                | self     | `rotate-secret.sh sshkey`, then wire the new public half into nix              |
| `tailscale_auth_key`                                                 | `homeserver-gcp`                | provider | Tailscale admin console → `rotate-secret.sh set`                               |
| `b2_credentials` / `restic_repository`                               | `main`,`homeserver-gcp`         | provider | Backblaze B2 console / `b2` CLI → `rotate-secret.sh set`                       |
| `alertmanager_webhook_url`                                           | `homeserver-gcp`                | provider | regenerate at the notification target → `rotate-secret.sh set`                 |
| `heartbeat_ping_url`                                                 | `homeserver-gcp`                | provider | regenerate at the heartbeat service → `rotate-secret.sh set`                   |
| `wpa_supplicant_wlp3s0_conf`                                         | `mac`                           | provider | new Wi-Fi PSK → `rotate-secret.sh set`                                         |
| `github_runner_homeserver_deploy_token`                              | `homeserver-gcp`                | provider | GitHub fine-grained PAT (browser) → `rotate-secret.sh set`; see worked example |
| `claude-credentials.json`, gcloud ADC, gemini oauth, `gh-hosts.yaml` | `&user`                         | capture  | re-run the tool's login, capture the file into sops                            |
| `git_user_name` / `git_user_email`                                   | `&user`                         | —        | static identity, not a rotating credential                                     |

**Trigger** for any entry: suspected exposure (logged, copied to an untrusted
host, leaked artifact), a planned periodic rotation, or staff/device change. A
host-key or `&user`-key compromise additionally triggers the host-key /
root-secret rotations described above and re-encryption of everything that key
could read.

### Caveats — these are not a blind value swap

- **`restic_password`** encrypts the repository; snapshots stay readable only
  under the key they were written with. Rotate with `restic key add` then
  `restic key remove` against the live repo _before_ updating the sops value, or
  you lose access to existing snapshots.
- **`grafana_secret_key`** encrypts datasource credentials stored in Grafana's
  database; replacing it without re-encrypting those breaks them. Rotate through
  Grafana's own procedure, not just the sops value.
- **`grafana_admin_password`** is consumed at first DB init; changing the sops
  value does not retroactively reset an existing admin user — update it in
  Grafana as well.
- **Host SSH / age keys** are not in scope for this helper: see
  [Host Key Rotation](#host-key-rotation) (`sops updatekeys` + `.sops.yaml`).

### Worked example — `github_runner_homeserver_deploy_token`

This fine-grained PAT registers the self-hosted runner and is more load-bearing
since `homeserver-gcp` auto-deploys on every push to `main` (see the host
runbook). Fine-grained PATs cannot be minted by the API, so the first step is
manual:

1. GitHub → Settings → Developer settings → Fine-grained tokens → generate a new
   token scoped to this repo only, with repository **Administration**
   read/write, matching the existing token. Copy it once.
2. Write it byte-safely and verify the round-trip:
   ```bash
   printf '%s' "$NEW_PAT" \
     | bash scripts/rotate-secret.sh set \
         hosts/homeserver-gcp/secrets/secrets.yaml \
         github_runner_homeserver_deploy_token
   ```
3. Commit and push. The change is inside the deploy workflow's path filter, so
   `homeserver-gcp` redeploys itself and the runner re-registers with the new
   token. Confirm the runner is online (repo → Settings → Actions → Runners) and
   that a subsequent deploy run is green.
4. Delete the old PAT in GitHub once the new one is confirmed working.

## Initrd SSH Recovery

`main` exposes initrd SSH on port `2222` only during stage 1 as a fallback for
TPM/LUKS unlock failures.

Constraints:

- Recovery requires wired Ethernet; WiFi is not available in stage 1.
- Authorized keys come from `lib/recovery-pubkeys.nix`.
- Day-to-day SSH access remains on the standard `lib/pubkeys.nix` path.
- The initrd SSH host key is stored as a sops secret.
- `flush-network-before-stage2` tears down non-loopback interfaces before stage 2.

Recovery key management:

- Keep the recovery private key offline; it is not part of normal SSH access.
- Rotate recovery access by updating `lib/recovery-pubkeys.nix`, removing the old
  public key, and redeploying `main` before relying on the new key.

Recovery flow:

```bash
ssh -i /path/to/id_ed25519_recovery -p 2222 root@<host-ip>
```

Then enter the LUKS passphrase when prompted.

## Impermanence And Local State

`main` uses an impermanent Btrfs root. The encrypted filesystem contains
separate `@root`, `@home`, `@nix`, and `@persist` subvolumes. During initrd,
`rollback-root.service` moves the current `@root` aside to top-level
`old_roots/<timestamp>` and recreates `@root` from the empty `@root-blank`
snapshot. Anything not on `/home`, `/nix`, `/persist`, or explicitly
bind-mounted from `/persist` is disposable.

Persistent `main` state is intentionally explicit:

- machine identity and SSH host keys;
- NetworkManager Wi-Fi/VPN profiles;
- Mullvad account/device state and relay cache;
- Tailscale node identity;
- Bluetooth, fingerprint, USBGuard, Secure Boot PKI, logs, coredumps, and NixOS state.

Adding a persistent path is a security decision. Copy live service state into
`/persist` first, then add the path to `hosts/main/impermanence.nix`; otherwise
the next rollback boot may bind an empty directory over the live path.

## Network Exposure

Tailscale is the primary remote-access layer.

- `homeserver-gcp` exposes SSH and HTTPS only on `tailscale0`; it does not globally open TCP `22` or `443`.
- Terraform adds a high-priority GCP firewall deny for public TCP `22` on the
  default VPC, so the tailnet-only SSH boundary is enforced at the cloud edge as
  well as by the in-guest firewall.
- `homeserver-gcp` obtains TLS material through `tailscale-cert.service`; ACME is not used.
- `homeserver-gcp` exposes HTTPS on the tailnet FQDN from `lib/hosts.nix`.
- Observability ingest is limited to exact push endpoints protected with basic auth sourced from sops:
  `/obs/loki/loki/api/v1/push`, `/obs/mimir/api/v1/push`, and
  `/obs/otlp/v1/traces`. Broader `/obs/*` API paths are denied so ingest
  credentials cannot read or query Loki, Mimir, or OTLP APIs through nginx.
- `homeserver-gcp` runs blackbox probes from inside the tailnet boundary against `https://<tailnet-fqdn>/` (Vaultwarden; expect `200/301/302`) and `https://<tailnet-fqdn>/grafana/` (Grafana auth-proxy path; expect `200` from the server's tailnet node identity).
- `main` enables SSH but does not open the normal firewall path for general LAN access.
- `mac` enables SSH and Syncthing listen ports only on `tailscale0`; it is not
  a public service host.
- `main` opens Input Leap and Sunshine ports only on `tailscale0` for the
  companion Mac workflow.

Tailscale ACL output is generated by `lib/acl.nix`. Access is derived from
registry metadata in `lib/hosts.nix`: `tailscale.acceptFrom` defines approved
inbound TCP ports per source tag. Same-tag peer access is not inferred from tag
reuse; it must be modeled with `acceptFrom` on the destination host. The
generated rules preserve destination port lists and do not add reverse wildcard
rules for return traffic. `tailnetFQDN` is used when host-specific destinations
need a stable tailnet name.

`autogroup:admin` intentionally owns generated tags and keeps `*:*` tailnet
break-glass access. This means a Tailscale admin can assign node tags and bypass
normal service ACLs during recovery. That is accepted for this personal
single-operator tailnet; deployments that separate platform administration from
day-to-day service access should replace this with narrower owner groups and
non-wildcard admin ACLs.

Drift between the rendered ACL and the live tailnet policy is checked by
`.github/workflows/tailscale-acl-drift.yml` via
`scripts/check-tailscale-acl-drift.sh`.

Grafana is exposed through nginx at `/grafana/` with Tailscale identity resolved
by a localhost auth helper. Grafana's auth-proxy listener trusts requests from
`127.0.0.1`, so local processes and SSH users on `homeserver-gcp` can reach the
Grafana listener directly and spoof auth-proxy headers. This is an accepted
local break-glass boundary for the current host model. If untrusted shell users
or untrusted local services are added later, move the nginx-to-Grafana boundary
to a Unix socket or equivalent nginx-only channel before relying on Grafana
roles as a local security boundary.

## Shielded VM

`homeserver-gcp` runs as a GCE Shielded VM. `infra/main.tf` sets
`shielded_instance_config` with vTPM and integrity monitoring enabled, giving a
hardware root of trust and a boot-integrity baseline that flags unexpected boot
measurement changes in the GCP console.

Secure Boot is deliberately left **off**: stock NixOS produces no signed boot
artifacts, so enabling it would leave the VM unbootable until the image adopts
lanzaboote-style signing. The Terraform block enforces these values rather than
inheriting them as an unmanaged provider default, and the drift guard
(`bash scripts/validate.sh tf-drift`) catches any future regression in live
state.

## USBGuard

`main` uses USBGuard with a deny-default posture. The checked-in policy should
only allow devices that are intentionally trusted. Adding a new USB device
should be done by vendor/product ID and reviewed as a security change.

## Systemd Hardening

The `services.hardened` DSL in `modules/nixos/services/hardened.nix` applies a
baseline sandbox to selected services. Service-specific relaxations should be
documented in the host module near the service they affect.

The public module contract and examples live in
`docs/modules/services-hardened.md`.

Validation coverage includes:

- native NixOS assertions for local module safety contracts, such as SOPS-backed initrd secret paths and hardening DSL usage;
- invariant checks for high-level host expectations;
- `profile-hardening` NixOS test for sandbox behavior;
- service-specific smoke tests for GCP homeserver paths.

## Validation Model

Security validation is split by where each rule belongs:

- Native NixOS assertions fail normal host evaluation for local module
  contracts. Use them when a module defines or consumes the option and an
  invalid value should block `nixos-rebuild`, such as SOPS-backed initrd secret
  paths, SSH/fail2ban coupling, or exact per-host Nix trusted users.
- Native NixOS warnings are for suspicious settings that should be visible but
  may be valid during a deliberate exception, such as globally exposed SSH on a
  tailnet-first host.
- Flake invariant checks cover fleet-level policy, host registry consistency,
  backup coverage, and generated-output expectations where the NixOS module
  system is not the natural owner.
- NixOS VM tests and smoke tests cover behavior that must be observed at
  runtime rather than inferred from evaluated options.

## Scoped Agent Maintenance Sudo

`main` keeps `security.sudo.wheelNeedsPassword = true`. It also declares a
narrow `security.sudo.extraRules` allowlist for the primary user so interactive
agents can perform repeat maintenance without a password prompt. The allowlist
lives in `agentMaintenanceCommands` in `hosts/main/default.nix`.

Allowed command categories are limited to:

- starting/statusing the local Restic backup and check units;
- `bootctl` status/cleanup;
- deleting an explicitly named EFI boot entry with `efibootmgr -b XXXX -B`;
- Nix garbage collection through the fixed-argument `nix-gc-14d` wrapper;
- local `main` activation through the fixed-argument `nixos-switch-main`
  wrapper.

Do not broaden this to full passwordless sudo. Additions should be exact-command
maintenance operations and should keep normal interactive sudo passworded.
The `nixos-switch-main` exception is root-equivalent because it activates from
the user-writable `/home/user/nix` checkout; keep it as the only passwordless
switch path unless a future reviewed immutable activation flow replaces it.

## Deploy And Bootstrap Sudo

Some non-`main` paths intentionally keep broad passwordless root after SSH
access because the current deploy flow depends on it:

- `hosts/mac` sets `security.sudo.wheelNeedsPassword = false` so deploy-rs can
  activate the companion workstation over Tailscale.
- `hosts/homeserver-gcp` sets `security.sudo.wheelNeedsPassword = false` for
  deploy-rs activation over Tailscale-scoped SSH.
- `modules/nixos/profiles/machine-dev.nix` sets passwordless wheel for
  disposable development machines and microVM guests that import it.
- The stock GCP bootstrap image creates a temporary `bootstrap` user with
  `NOPASSWD:ALL` so `nixos-anywhere` can install NixOS.

This is a deliberate deploy convenience tradeoff: whoever obtains one of those
SSH identities effectively obtains root on that target. Do not use these
profiles for multi-user or untrusted-shell hosts without replacing broad wheel
sudo with a dedicated deploy user and a reviewed command allowlist.

For the GCP bootstrap path, `scripts/deploy-gcp.sh` removes and verifies removal
of the bootstrap-only metadata keys after a successful install. Removing the
startup-script metadata prevents the temporary bootstrap user and sudoers entry
from being recreated by later OpenTofu applies; the bootstrap OS itself is
replaced by the installed NixOS system.

## Audit Timeline In Loki

Security-relevant host events are shipped to Loki through the existing Alloy
journald pipeline.

The general journal stream keeps broad operational coverage under
`job="systemd-journal"`. A second narrow stream keeps incident-focused events
under `job="audit-journal"` with stable labels:

- `audit_event_type` for the event class, currently `sudo`, `ssh`, or `service_failure`;
- `audit_scope` for the operational area, such as `operator-actions` or `remote-access`;
- `audit_source` for the configured selector name;
- `unit`, `syslog_identifier`, `priority`, and `comm` when journald exposes them.

Current built-in selectors intentionally stay narrow:

- `SYSLOG_IDENTIFIER=sudo`
- `_SYSTEMD_UNIT=sshd.service`
- `SYSLOG_IDENTIFIER=systemd PRIORITY=3`

Use host-specific `profiles.observability.collectors.audit.extraSources` only
for additional high-signal selectors. This is the extension point for things
like a stable secret-materialization unit if a host exposes one; do not turn it
into a broad "ship every auth-related log twice" rule set.

Common LogQL queries:

- `{job="audit-journal"}`
- `{job="audit-journal",audit_event_type="sudo"}`
- `{job="audit-journal",audit_event_type="ssh"}`
- `{job="audit-journal",audit_event_type="service_failure"}`
- `{job="audit-journal",host="main"} |= "session opened"`

Grafana renders these through the `Security Events` dashboard on
`homeserver-gcp`.

## Backups

Backup policy is driven by `hostMeta.backup.class` from `lib/hosts.nix` and
implemented by `modules/nixos/profiles/backup.nix`. For how these backups are
_validated_ — the restore canary, freshness metrics, stale alerts, and config
invariants that turn "backed up" into "proven restorable" — see
[`backup-validation.md`](backup-validation.md).

Current classes:

| Class      | Retention                               |
| :--------- | :-------------------------------------- |
| `critical` | 14 daily, 8 weekly, 6 monthly, 2 yearly |
| `standard` | 7 daily, 4 weekly, 3 monthly            |

`hostMeta.backup.name` selects the restic job to receive that policy and
defaults to `local`. `main` uses `local`; `homeserver-gcp` uses `b2` for
Backblaze B2 off-site backups.

`main` extends the shared backup profile with workstation-specific paths in
`hosts/main/backups.nix`. The backup covers selected user state plus the
persistent identities needed after a full reinstall: Codex and Claude state,
Wi-Fi profiles, Mullvad account/device state, Tailscale node identity,
Bluetooth pairings, fingerprint enrollment state, USBGuard rules, Secure Boot
PKI, machine-id, SSH host identity, and libvirt/Whonix VM state. Large or
volatile libvirt artifacts such as ISOs, snapshots, save/dump images, and RAM
state are excluded.

## Mullvad and Tailscale Coexistence

`main` runs Mullvad VPN and Tailscale concurrently. The two VPNs conflict at
the routing and kill-switch layers; three mechanisms hold them together.

**nftables kill-switch bypass.** Mullvad's kill-switch nftables chain (priority 0)
blocks traffic that lacks its split-tunnel exclusion mark (`0x6d6f6c65`). The
`tailscale-mullvad-compat` nftables table adds a chain at priority −1 that
marks all outgoing `tailscale0` packets with that value before Mullvad's chain
runs. This makes Mullvad's kill switch pass tailnet traffic unconditionally,
without weakening it for clearnet traffic.

**Policy routing priority.** Mullvad installs a broad policy routing rule that
routes most traffic through its own table, which would also capture
`100.64.0.0/10` CGNAT (Tailscale addresses). `tailscale-bypass-routing.service`
(also fired in `tailscaled.postStart` and `mullvad-daemon.postStart`) adds
destination-specific policy rules at pref 114 for `100.64.0.0/10` and
`fd7a:115c:a1e0::/48`, pointing at Tailscale's routing table. These beat
Mullvad's catch-all rule for tailnet destinations. The service retries up to
five times to handle daemon startup ordering.

**Reverse-path filtering.** The dual-VPN setup produces asymmetric routes that
strict reverse-path filtering rejects as spoofed. `networking.firewall.checkReversePath`
is set to `"loose"` for the main interface to allow the legitimate tunneled
return traffic.

In the anonymous specialisation Tailscale is fully disabled, so all three
mechanisms are removed and `checkReversePath` is forced back to `"strict"`.

## Anonymous Specialisation

`main` has a boot-selectable `anonymous` specialisation for pentest and
Tor-browsing work. It appears as a separate bootloader entry
(`nixos-anonymous-...`); select it from the bootloader menu on boot.

**Design model — what this is and is not.** The specialisation is an _amnesic,
hardened launchpad_, not an anonymous OS. The host is pseudonymous at best:
treat its job as (a) a kill-switched, telemetry-free, randomised-identity base
and (b) a stable place to run the Whonix VMs. The three roles are deliberately
separated:

- **Active pentest scanning → Mullvad.** Mullvad is the origin-hiding layer:
  it hides your home IP from the target with full protocol support (SYN/UDP/raw
  scans, full speed). This is the conventional pentest egress.
- **Origin-sensitive OSINT/recon → Tor** via `proxychains`/`torsocks` (TCP
  `connect()` only — see below).
- **Anonymous browsing → Tor Browser inside Whonix-Workstation.** This is the
  only genuinely anonymous surface here, because the Workstation VM has no route
  to the internet except through the Gateway's Tor (fail-closed by topology, not
  by config). Do not use the host browser for anonymity — it exits via Mullvad,
  not Tor, and (outside the amnesic spec) carries your real logins.

**Changes from normal boot:**

| Area          | Normal                    | Anonymous                                                                             |
| :------------ | :------------------------ | :------------------------------------------------------------------------------------ |
| `/home/user`  | persistent `@home`        | tmpfs — amnesic, HM repopulates dotfiles from the store each boot                     |
| machine-id    | stable (persisted)        | fresh transient value each boot                                                       |
| Hostname      | `main`                    | `nixos` (domain cleared)                                                              |
| Wi-Fi MAC     | stable                    | random per connection                                                                 |
| Ethernet MAC  | stable                    | random per link                                                                       |
| Bluetooth     | enabled                   | disabled                                                                              |
| SSH           | enabled (tailscale0 only) | disabled                                                                              |
| Tailscale     | enabled                   | disabled                                                                              |
| Observability | Prometheus, Alloy, OTel   | all disabled                                                                          |
| Backups       | Restic + btrbk timers     | all disabled                                                                          |
| AppArmor      | disabled                  | enabled                                                                               |
| Mullvad       | running, manual connect   | running, auto-connect + explicit connect, lockdown always on                          |
| Tor           | not running               | SOCKS5 client on `127.0.0.1:9050`                                                     |
| proxychains   | no system config          | `strict_chain` → Tor `127.0.0.1:9050`, `proxy_dns` on                                 |
| Kernel        | default                   | `dmesg_restrict=1`, `kptr_restrict=2`, `perf_event_paranoid=3`, `yama.ptrace_scope=1` |

**Amnesic home.** `/home/user` is a tmpfs in this spec, so every anonymous boot
starts with no logins, cookies, shell history, or scan artifacts. Home Manager
repopulates declarative dotfiles from the Nix store on boot, so the _configured_
environment survives while session _data_ does not. The real `@home` is not
wiped — it is shadowed by the tmpfs while this spec is booted, and reappears on
a normal boot.

The anonymous specialisation also overrides the normal persistence directory
list down to the minimum required system state. Persistent Tailscale identity,
saved Wi-Fi/VPN profiles, Bluetooth pairings, fingerprint enrollment, Mullvad
account/device state, logs, and libvirt state are not bind-mounted into the
anonymous boot.

Anything you want to keep from an anonymous session (loot, notes)
must be copied off-host before reboot; there is no persistent scratch directory
by default.

**Traffic model in anonymous mode:**

- All clearnet traffic exits through Mullvad with kill-switch on; nothing
  escapes if Mullvad disconnects. The spec sets `mullvad auto-connect` _and_
  issues an explicit `mullvad connect` on boot, so the first anonymous boot has
  connectivity rather than sitting locked-down-but-disconnected.
- `proxychains <tool>` routes the tool's TCP through Tor (Mullvad → Tor exit).
  `proxy_dns` is on, so DNS also resolves through Tor. `strict_chain` means it
  fails closed — if Tor is still starting, connections fail rather than leaking
  direct.
- **SOCKS carries TCP `connect()` only.** `nmap -sS` (SYN), UDP scans, ICMP/ping
  sweeps, and `masscan` bypass the proxy entirely — they do **not** go through
  Tor. Only use `proxychains` for TCP tools (`nmap -sT -Pn`, `curl`, recon HTTP
  tools). For active scanning, exit via Mullvad instead; do not assume
  `proxychains` torifies a raw scanner.
- Whonix VMs route through the host network stack and therefore also through
  Mullvad; their internal Tor traffic exits through Mullvad's tunnel.

**Security shell and Tor.** `nix develop#security` provides network recon,
web, password, and packet-analysis tools. In the anonymous specialisation,
`proxychains <tool>` chains TCP through Tor; for hardened fail-closed behaviour
on TCP tools, `torsocks <tool>` is an alternative. In the normal boot,
`proxychains` fails loudly because no Tor daemon is running — this is
intentional; tools should not silently run direct while appearing to be proxied.

**Whonix KVM.** Whonix-Gateway and Whonix-Workstation are installed as
persistent KVM/libvirt VMs. Images live in `/var/lib/libvirt/images/`
(bind-mounted from `/persist/var/lib/libvirt/` for impermanence survival).
`Whonix-External` and `Whonix-Internal` libvirt networks autostart. Start
Gateway before Workstation; updates run inside the VMs as `sysmaint` using
`upgrade-nonroot` (the `user-sysmaint-split` feature blocks `sudo` from the
normal `user` account).

The main B2 restic backup includes `/var/lib/libvirt` so the configured VMs can
survive disk loss; installer ISOs, transient snapshots, and runtime
save/dump/RAM artifacts are excluded from that backup.

Whonix is kept **persistent** on purpose — it is the configured, updated
anonymity appliance, not throwaway. That means Tor Browser state accumulates
inside the Workstation across sessions; use Tor Browser's "New Identity" for
session separation. Per-session VM amnesia (libvirt external-snapshot/overlay
revert, or Whonix Live mode) is a deliberate future hardening step, not yet
configured.
