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
- `homeserver-gcp` obtains TLS material through `tailscale-cert.service`; ACME is not used.
- `homeserver-gcp` exposes HTTPS on the tailnet FQDN from `lib/hosts.nix`.
- Observability ingest is limited to exact push endpoints protected with basic auth sourced from sops:
  `/obs/loki/loki/api/v1/push`, `/obs/mimir/api/v1/push`, and
  `/obs/otlp/v1/traces`. Broader `/obs/*` API paths are denied so ingest
  credentials cannot read or query Loki, Mimir, or OTLP APIs through nginx.
- `homeserver-gcp` runs blackbox probes from inside the tailnet boundary against `https://<tailnet-fqdn>/` (Vaultwarden; expect `200/301/302`) and `https://<tailnet-fqdn>/grafana/` (Grafana auth boundary; expect `403` from the server's tagged-device identity).
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

## USBGuard

`main` uses USBGuard with a deny-default posture. The checked-in policy should
only allow devices that are intentionally trusted. Adding a new USB device
should be done by vendor/product ID and reviewed as a security change.

## Systemd Hardening

The `services.hardened` DSL in `modules/nixos/services/hardened.nix` applies a
baseline sandbox to selected services. Service-specific relaxations should be
documented in the host module near the service they affect.

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
- Nix garbage collection through the fixed-argument `nix-gc-14d` wrapper.

Do not broaden this to full passwordless sudo. Additions should be exact-command
maintenance operations and should keep normal interactive sudo passworded.
Do not add passwordless rebuild/switch commands that activate from
user-writable paths such as `/home/user/nix`; switching `main` should require a
normal passworded sudo boundary or a future reviewed immutable activation flow.

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
implemented by `modules/nixos/profiles/backup.nix`.

Current classes:

| Class      | Retention                               |
| :--------- | :-------------------------------------- |
| `critical` | 14 daily, 8 weekly, 6 monthly, 2 yearly |
| `standard` | 7 daily, 4 weekly, 3 monthly            |

`hostMeta.backup.name` selects the restic job to receive that policy and
defaults to `local`. `main` uses `local`; `homeserver-gcp` uses `b2` for
Backblaze B2 off-site backups.

`main` extends the shared backup profile with workstation-specific paths in
`hosts/main/default.nix`. The backup covers selected user state plus the
persistent identities needed after a full reinstall: Codex and Claude state,
Wi-Fi profiles, Mullvad account/device state, Tailscale node identity,
Bluetooth pairings, fingerprint enrollment state, USBGuard rules, Secure Boot
PKI, machine-id, and SSH host identity.
