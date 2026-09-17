# Secrets-scoping audit (fleet-wide, sops-nix) — 2026-09-18

Read-only audit of `.sops.yaml`, every encrypted file under `hosts/*/secrets/`,
`home/users/user/secrets/` and `tests/fixtures/`, every `sops.secrets.*`
declaration across `hosts/{main,mac,homeserver-gcp,gcp-builder,gcp-agent}` and
the shared modules they import, and the secrets/escrow/rotation docs. No files
were changed and nothing was decrypted: recipient lists and cleartext key names
were read from the public `sops:` metadata block only. The policy under test is
`CLAUDE.md` "Scope secrets appropriately. Each host should only be able to
decrypt the secrets it needs, as defined in `.sops.yaml`", plus the owner's
current situation: the three GCP hosts are paused pending physical hardware.

Live state that colours the high-severity findings (verified via CLI):

- The repo `FilipNowakowicz/nixos-config` is **PUBLIC** (`gh repo view`). Every
  ciphertext in this report is world-readable; only the age recipients' private
  keys stand between the internet and the values.
- The GCP project has **billing disabled**: every Compute API call (`instances
list/describe`, `disks list`, `snapshots list`) fails with "requires billing to
  be enabled". The power state, disks and snapshots of `homeserver-gcp`,
  `gcp-builder` and `gcp-agent` cannot be inspected or deleted from here.
- Tailscale on `main` is stopped (`tailscale status`), so nothing can be checked
  over the tailnet either.
- `main`'s live host key converts to `age1nn999…0v2c0f` (`ssh-to-age`), matching
  `.sops.yaml:6`; the personal key is `~/.config/sops/age/keys.txt`, mode 0600 in
  a 0700 directory; sops in the dev shell is 3.13.3.

Confidence labels: **verified** (live check, git history, tool output or upstream
source read), **plausible** (strong inference, not directly observed),
**speculative**.

---

## 0. Recipient matrix (what each key can open today)

Embedded recipients were read from each file's `sops.age[].recipient` entries and
compared with the rule that matches its path. All 21 files agree with their rule.

| Files                                                                                                              | Rule (`.sops.yaml`) | Embedded recipients                                                                             |
| :----------------------------------------------------------------------------------------------------------------- | :------------------ | :---------------------------------------------------------------------------------------------- |
| `hosts/main/secrets/secrets.yaml`, `hosts/main/secrets/gcp_builder_build_key.enc`                                  | `:25-29`            | `&user` + `&main_host`                                                                          |
| `hosts/mac/secrets/{secrets.yaml, luks-keyfile.enc, ssh_host_ed25519_key.enc, .pub.enc}`                           | `:35-39`            | `&user` + `&mac_host`                                                                           |
| `hosts/homeserver-gcp/secrets/{secrets.yaml, ssh_host_ed25519_key.enc, .pub.enc}`                                  | `:30-34`            | `&user` + `&homeserver_gcp_host`                                                                |
| `hosts/gcp-agent/secrets/{claude-credentials.enc, gcp_builder_build_key.enc, gh-hosts.yaml, host key ×2}`          | `:40-44`            | `&user` + `&gcp_agent_host`                                                                     |
| `home/users/user/secrets/{claude-credentials.json, gcloud-…json, gemini-…json, gh-hosts.yaml, user-identity.yaml}` | `:21-24`            | `&user` only                                                                                    |
| `tests/fixtures/sops-host/secrets/secrets.yaml`                                                                    | no rule             | fixture key `age14arp…` only (private half committed at `tests/fixtures/sops-host/age-key.txt`) |

Declared-vs-stored key names, per host (cleartext key names only):

- `main` — `hosts/main/default.nix:599-612` declares `user_password`,
  `observability_ingest_password`, `restic_password`, `restic_repository`,
  `b2_credentials`, `initrd_ssh_host_ed25519_key`; `secrets.yaml` holds exactly
  those six. `hosts/main/nix-remote-build.nix:20-24` adds `gcp_builder_build_key`
  from its own `.enc`. **Verified.**
- `mac` — `hosts/mac/default.nix:284-305` declares `user_password`,
  `root_password`, `wpa_supplicant_wlp3s0_conf`, `observability_ingest_password`
  (file holds exactly those four) and `luks_keyfile` from `luks-keyfile.enc`.
  **Verified.**
- `homeserver-gcp` — `hosts/homeserver-gcp/default.nix:243-287` declares twelve,
  `hosts/homeserver-gcp/adguard.nix:50` a thirteenth (`adguard_admin_password`);
  `secrets.yaml` holds exactly those thirteen. **Verified.**
- `gcp-agent` — `hosts/gcp-agent/default.nix:286-306` (`claude_credentials`,
  `gh_hosts`) and `hosts/gcp-agent/nix-remote-build.nix:30-35`
  (`gcp_builder_build_key`), each from its own file. **Verified.**
- `gcp-builder` — `sops = false` (`lib/hosts.nix:125`), no `sops.*` anywhere in
  `hosts/gcp-builder/`, and `git log -p -- .sops.yaml` shows it was never a
  recipient. **Verified.**

So in the narrow sense the policy holds: no host key is a recipient on any file
outside its own directory, and every file a host can open is consumed by that
host's config. The findings below are about the _lifetime_ and _provenance_ of
that capability, which is where the paused-hosts question actually bites.

## 1. High

1. **`.sops.yaml:10` — the live `&homeserver_gcp_host` identity is the pre-hardening key that transited GCE instance metadata, and the hardening rotation was silently reverted.**
   At `23d2789` (2026-05-03) `.sops.yaml:20` already carried
   `age13av6m…c3hqg6`, while `hosts/homeserver-gcp/default.nix:25-43` of that
   commit fetched the _private_ host key from
   `metadata.google.internal/…/attributes/ssh-host-key-b64` and
   `infra/main.tf:85-90` set `ssh-host-key-b64 = var.ssh_host_key_b64` (an
   OpenTofu variable, hence also in tfstate). `7921c83` (2026-05-21, "Harden GCP
   bootstrap secrets") removed that flow, rotated the anchor to `age13at2l…kkkw6`
   and added the caveat now at `docs/security.md:98-106` ("verify
   `ssh-host-key-b64` is absent from instance metadata, ignored `infra/*.tfstate*`,
   logs, and backups; if that cannot be proven, also rotate credentials
   decryptable by `&homeserver_gcp_host`"). `e041b00` (2026-05-22, "deploy
   fixes", empty body) put `age13av6m…` back and re-encrypted both host-key
   `.enc` files to it; `secrets.yaml` was last re-encrypted to it on 2026-06-09
   (`lastmodified`). Nothing in the tree mentions `age13at2l` or the revert.
   Today's local `infra/terraform.tfstate{,.backup}` contain zero `ssh-host-key`
   entries (name match, no values read) but date from 2026-06-12; the live
   metadata cannot be checked (billing disabled). Because the repo is public,
   anyone who read that metadata value between 05-03 and 05-21 (any project
   viewer, anything with metadata-server access on the VM, any copy of the
   old tfstate) can decrypt the current `hosts/homeserver-gcp/secrets/secrets.yaml`:
   `b2_credentials`, `restic_repository`, `restic_password`,
   `github_runner_homeserver_deploy_token` (a repo-**Administration** PAT that
   `hosts/homeserver-gcp/CLAUDE.md:85-87` itself calls "independently
   host-compromising"), `tailscale_auth_key`, `grafana_admin_password`,
   `grafana_secret_key`, `adguard_admin_password`, `alertmanager_webhook_url`,
   `heartbeat_ping_url`, `observability_ingest_htpasswd`, `user_password`,
   `homeserver_selfdeploy_ssh_key`. **Key identity and history verified; actual
   capture of the metadata value plausible, not proven.**
   Next: take the docs' own "cannot be proven" branch — rotate every value in that
   file (B2 key + `restic key add/remove`, the two PATs' peer at GitHub, Tailscale
   key, Grafana/AdGuard, webhook + heartbeat URLs, `rotate-secret.sh
observability`), mint a fresh host identity, and record the May revert in
   `docs/security.md` so the caveat is not read as historical.

2. **Paused GCP hosts hold live decrypt capability, and live provider credentials, on disks the owner cannot currently see or delete.**
   `&homeserver_gcp_host` and `&gcp_agent_host` are live recipients on 13 + 3
   real credentials (matrix above) that nothing consumes while the boxes are off,
   so the capability is pure liability. Where it physically lives: (a)
   `homeserver-gcp` has no impermanence (`hosts/homeserver-gcp/CLAUDE.md:4,23`), so
   its ext4 root holds `/etc/ssh/ssh_host_ed25519_key` (= the key in #1), the
   runner state dir's plaintext copies of the Administration PAT — nixpkgs
   `github-runner/service.nix:41,121-130` installs `tokenFile` as
   `.current-token` (0600) plus `.credentials` (verified from the pinned
   nixpkgs source; `hosts/homeserver-gcp/CLAUDE.md:178-179,198-199` describes the
   same), the non-ephemeral Tailscale node identity, the Grafana DB, and
   `/var/lib/vaultwarden` — which per `docs/key-escrow.md:40-42` is escrow location
   #1 for the `&user` root key (behind the Bitwarden master password, not sops).
   (b) `gcp-agent`'s root (`hosts/gcp-agent/disko.nix:25`, ext4, no impermanence)
   holds the host key that opens a Claude OAuth login, a GitHub PAT with
   contents/issues/PR write, and the SSH key that is root-equivalent on
   `gcp-builder` (`hosts/gcp-agent/nix-remote-build.nix:12-16`), plus the
   non-ephemeral tailnet identity (which the ACL lets reach `gcp-builder:22` and
   the homeserver's DNS, `lib/hosts.nix:96,122`). (c) `gcp-builder` has no key
   material beyond its tailnet identity and public halves. Daily 7-day boot-disk
   snapshots (`hosts/homeserver-gcp/CLAUDE.md:18`) would carry all of (a). None
   of this can be verified or cleaned up until billing is re-enabled — the API
   refuses every call — so the decrypt capability is, right now, outside the
   owner's control while the ciphertexts are public. **Disk contents verified by
   reading config + pinned sources; disk/snapshot existence plausible (the API
   cannot confirm either way).**
   Next: this is the most actionable item in the audit. Order matters (see
   Medium #1): rotate the values first, then remove `&homeserver_gcp_host` and
   `&gcp_agent_host` from `.sops.yaml`, run `sops updatekeys -y` **and**
   `sops rotate -i` on each affected file, set the three hosts to
   `status = "inactive"` in `lib/hosts.nix` (the parity invariant then _requires_
   the rules and anchors to go, `lib/invariants.nix:48-109`), revoke the two PATs
   and the three tailnet nodes in their consoles, and when billing returns delete
   the disks and snapshots or wipe them before reuse.

## 2. Medium

1. **`docs/security.md:95,169`, `docs/key-escrow.md:115`, `scripts/rotate-secret.sh:40` — every recipient-change procedure says `sops updatekeys` only, which does not revoke a removed recipient in a public repo.**
   `sops updatekeys --help`: "update the keys of SOPS files using the config
   file" — it re-wraps the _same_ data key for the new recipient set.
   `sops rotate --help`: "generate a new data encryption key and reencrypt all
   values with the new key". A removed host key can unwrap the unchanged data key
   from the previous git revision and decrypt the current ciphertext, and it keeps
   every value ever committed to the old revision forever. **Verified (tool help
   text + sops data-key model).**
   Next: make the procedure "`updatekeys` then `rotate -i`", and state plainly
   that in this public repo removing a recipient protects only _future_ values;
   anything the old key could read must be rotated at the provider.

2. **No pause/decommission procedure exists, and "paused" is not representable in the repo.**
   `grep -riE 'decommission|retire|pause|powered off'` over `docs/`, `CLAUDE.md`,
   `hosts/*/CLAUDE.md`, `.claude/` finds only the idle-shutdown notes.
   `docs/security.md` covers personal-key exposure (`:38-45`), host-key rotation
   (`:85-106`) and value rotation (`:108-192`) — all "rotate in place"; nothing
   says what happens to a host's recipient, provider tokens, tailnet node and disk
   when the host is switched off indefinitely or destroyed. Meanwhile the registry
   already has an `inactive` status (`lib/host-registry.nix:21-25`) wired into
   `checkSopsRecipientParity` (`lib/invariants.nix:48-56`) so that flipping it
   forces `.sops.yaml` cleanup — unused. Status is currently asserted in three
   places that disagree: `lib/hosts.nix:72,115,138` say `active`,
   `hosts/gcp-agent/CLAUDE.md:9` says `provisioning`, reality is paused. **Verified.**
   Next: add a "Pausing or decommissioning a host" section (revoke provider creds
   → rotate shared values → drop recipient → `updatekeys` + `rotate` →
   `status = "inactive"` → delete disk/snapshots/tailnet node) and apply it to the
   three GCP hosts now.

3. **`docs/security.md:136,140` + `hosts/main/backups.nix:53` — if `restic_password` / `b2_credentials` are shared between `main` and `homeserver-gcp`, High #1/#2 become a pivot into the `&user` root key.**
   The inventory lists `restic_password` and `b2_credentials`/`restic_repository`
   as single rows owned by `main`,`homeserver-gcp`; `.claude/main/recovery.md:110`
   shows `main`'s repo as `b2:<bucket>:/main`, i.e. a path inside a bucket. If the
   B2 application key is bucket-wide (not prefix-restricted) and/or the restic
   password is the same value on both hosts, the paused homeserver key reaches
   `main`'s restic repo, which backs up `/home/user/.config/sops`
   (`hosts/main/backups.nix:53`) — the root age key — and from there everything.
   Cannot be determined without decrypting. **Speculative-to-plausible.**
   Next: `sops -d --extract` both files and confirm the two `restic_password` and
   `b2_credentials` values differ; if a B2 key is shared, mint per-host keys with
   `namePrefix` restrictions and record the result in the inventory table.

4. **`hosts/gcp-agent/default.nix:290-305` — sops-managed `path=` secrets in `user`'s home can be replaced by plaintext on the persistent disk.**
   sops-nix installs custom-path secrets as symlinks into `/run/secrets.d`
   (`pkgs/sops-install-secrets/main.go:253-264`, pinned rev `13616fff`), so the
   sops copy is tmpfs-only. But `claude` rewrites `.credentials.json` on token
   refresh and `gh` rewrites `hosts.yml`, and `hosts/gcp-agent/CLAUDE.md:158-160`
   already acknowledges the live file diverging from the sops value — an atomic
   rewrite replaces the symlink with a regular file on the ext4 root. The refreshed
   OAuth/refresh tokens therefore likely sit in plaintext on the paused disk
   regardless of sops. **Symlink behaviour verified from source; divergence
   plausible.**
   Next: on resume, revoke the Claude session and the PAT _before_ first boot;
   longer term give `user` a tmpfs home on this host or mark the two files
   read-only-at-path and let the CLIs write elsewhere.

## 3. Low

1. **`hosts/mac/default.nix:115,285` + `hosts/mac/CLAUDE.md:29-37` — the mac host key (recipient on all mac secrets) is reachable without any passphrase.**
   `luks-keyfile.enc` decrypts on the host via `&mac_host`, whose private key is
   `/persist/etc/ssh/ssh_host_ed25519_key` inside LUKS — but the LUKS keyfile is
   baked into the initrd on the unencrypted ESP (`boot.initrd.secrets`). Physical
   possession of the disk therefore yields the host key and with it the Wi-Fi PSK,
   both password hashes and the ingest password. The trade-off is documented for
   the disk; its sops consequence is not. **Verified by reading.**
   Next: one sentence in the runbook; follow the documented keyfile removal before
   the laptop travels.

## 4. Doc/code drift

1. **`docs/security.md:23`** — says `main` and `homeserver-gcp` use SSH-derived
   identities via `sops.age.sshKeyPaths`; all four sops hosts do
   (`modules/nixos/profiles/sops-base.nix:11` default; `main`/`mac` override to
   `/persist`, `hosts/main/default.nix:600`, `hosts/mac/default.nix:285`).
   **Verified.** Next: say "every sops host".
2. **`docs/security.md:34`** — "Planned Home Manager user-secret backups" have
   been live since `f5b9b27` (2026-05-17): five files,
   `home/users/user/secrets.nix:39-66`, enabled on `main`
   (`home/users/user/home.nix:326`), disabled on `mac` (`home/users/user/mac.nix:6`),
   never imported by the `agent`/`server` roles. **Verified.** Next: drop "Planned".
3. **`docs/security.md:129-148` (inventory)** — omits `luks_keyfile` (mac),
   `gcp_builder_build_key` (main _and_ gcp-agent; rotation lives only in
   `hosts/gcp-builder/CLAUDE.md:151-160`), and the three pre-baked
   `ssh_host_ed25519_key.enc` pairs; lists `user_password` as "all" although
   `gcp-agent` provisions no password (`hosts/gcp-agent/default.nix:308-310`); and
   the Host Key Rotation section never records that the May homeserver rotation was
   reverted (High #1). **Verified.** Next: complete the table and add the revert note.
4. **`hosts/gcp-agent/CLAUDE.md:9`** vs **`lib/hosts.nix:138`** — "Status:
   provisioning" vs `status = "active"`; neither is "paused". **Verified.** Next:
   Medium #2.

## 5. Test/invariant coverage gaps

1. **No check that each encrypted file's embedded recipients equal its `.sops.yaml` rule.** `checkSopsRecipientParity` (`lib/invariants.nix:58-109`) parses only
   the `.sops.yaml` text; a file left encrypted to a removed key (missed
   `updatekeys`), or encrypted to an extra recipient, passes silently. The
   recipient list is public metadata, so a key-less CI check can parse
   `sops.age[].recipient` from every file under `hosts/*/secrets/` and
   `home/users/user/secrets/` and diff it against the matching rule. Today all 21
   files agree (Section 0), so the check would start green. Next: add to
   `flake/checks.nix` next to the `*-sops-bootstrap` checks, which currently only
   assert the `.enc` files _exist_ (`flake/checks.nix:648-662,693-695`).
2. **`lib/invariants.nix:65,71`** — the parity check verifies that each active
   sops host has _a_ rule and _an_ anchor; it does not assert that each
   `hosts/<h>/secrets/` rule's key group is exactly `[&user, &<h>_host]`, so a
   second host's anchor accidentally added to a rule would pass. Cheap to extend.
   Next: assert group equality per rule.
3. **`tests/fixtures/sops-host/age-key.txt`** — a committed private age key whose
   recipient `age14arp…` appears in exactly one file (the fixture; grep across the
   tree). Fine today, but the regex in gap #2 never sees `tests/`, so a real
   secret encrypted to the fixture key would go unnoticed. Next: covered by gap #1
   if the file sweep is fleet-wide and the fixture key is explicitly denied.

---

## Checked and fine

- Every encrypted file's embedded recipient set equals its `.sops.yaml` rule; no
  file is encrypted to a recipient outside its rule; `home/users/user/secrets/*`
  is `&user`-only as `docs/security.md:34` claims.
- Every `sops.secrets.<name>` on every host resolves to a key present in a file
  that host's own key can decrypt, and the four per-host `secrets.yaml` files
  contain exactly the keys their host declares (6 / 4 / 13 / n/a) — no unused
  keys, no host consuming another host's file.
- No orphaned recipients: the five anchors map to `&user` plus the four sops
  hosts in `lib/hosts.nix`; the historical `vm_host`, `homeserver_vm_*`,
  `homeserver_host` and two earlier `main_host` keys were removed in `cf574ab`,
  `967ee04`, `3714fb5`, `b7cf47f` (git history) and `gcp-builder` was never added.
- `gcp-agent` really does not carry the `&user` key
  (`home/users/user/agent.nix:4-5,35` imports only `common.nix`; no
  `sops.age.keyFile`), and its build key to `gcp-builder` is distinct from `main`'s
  (two different public keys, `hosts/gcp-builder/default.nix:206-207`).
- The personal key exists only where Home Manager enables `userSecrets` (`main`),
  0600 in a 0700 directory (live); `main`'s live host key matches `.sops.yaml:6`
  (`ssh-to-age`, live), and `/persist/etc/ssh/ssh_host_ed25519_key` is root 0600.
- CI never decrypts anything: no `sops`/age references in `.github/` (grep); the
  homeserver auto-deploy decrypts on the host with the host's own key.
- `scripts/deploy-gcp.sh:40-52` decrypts the homeserver host key only into a
  `mktemp -d` with an `EXIT` trap, and current OpenTofu files pass no host-key
  material (`infra/*.tf`, name match).
- Plaintext under secrets directories is blocked at commit and in CI
  (`scripts/check-secrets-directory.sh`, `pre-commit-hooks.nix:72-76`,
  `tests/lib/secrets-directory.nix`, `.plaintext-secrets-allowlist` narrow); the
  `boot.initrd.secrets` assertion (`modules/nixos/profiles/sops-base.nix:17-22`)
  holds as the previous audit noted.

Suggested triage order: High #2 and Medium #1 together (rotate values, then
drop + `rotate` the two GCP recipients, flip `status`), High #1 (new homeserver
identity + doc note), Medium #3 (ten-second `sops -d --extract` check that
decides whether the B2 pivot is real), then Medium #2 (write the pause procedure
so this does not recur), then the doc sweep and the two cheap invariants.
