# Doc / shared-module drift audit — 2026-09-18

Read-only follow-up to `main-audit-2026-09-17.md`. Scope: `docs/architecture.md`, `docs/operations.md`, the remainder of `docs/security.md`, `README.md`, the four non-`main` host runbooks plus the root `CLAUDE.md` cross-links, and the shared modules under `modules/nixos/profiles/*`, `modules/nixos/services/*` (with the `lib/` files they import). Everything already listed in the 09-17 report is skipped (`docs/security.md:567-589,638,649-652`, `docs/operations.md:32,124-127`, `README.md:304`, `collectors.nix:634-668`, `security.nix:42-58`, and the `systemd-failure-notify` `/bin/cat` bug itself). No files were changed. Static code-vs-doc only; no live checks against the GCP hosts.

Baseline: `bash scripts/validate.sh flake-eval` passes on `1394e6d` (`all checks passed!`; the single warning is deploy-rs's usual `unknown flake output 'deploy'`). Where a claim could be settled by `nix eval` (PAM text, trusted keys, service defaults, dashboard paths, deploy nodes) it was.

Confidence labels: **verified** (eval, or source read end to end — including the pinned nixpkgs module where relevant), **plausible** (strong inference, not directly observed), **speculative**.

---

## 1. `docs/architecture.md`

1. **`docs/architecture.md:48`** — "The current global imports are `profiles/observability/`, `profiles/backup.nix`, `services/systemd-failure-notify.nix`, and `services/hardened.nix`." `modules/nixos/default.nix:3-10` imports six: also `profiles/meta.nix` (the `profiles.ci` option) and `profiles/nix-trusted-users.nix` (sets `nix.settings.trusted-users` unconditionally and adds two assertions). **Verified.** Next: list all six; note `nix-trusted-users.nix` is the one global import with an unconditional (if root-only) effect.

2. **`docs/architecture.md:104-107`, `README.md:292-295`** — "Hand-maintained `hardware-configuration.nix` files must carry a short header with their regeneration policy and a `Last reviewed:` note." Only `hosts/main` (`:1-7`) and `hosts/mac` (`:1-6`) comply; `hosts/gcp-agent`, `hosts/gcp-builder`, and `hosts/homeserver-gcp` `hardware-configuration.nix` all start at `{ modulesPath, ... }:` with no header, and no check enforces the rule. **Verified.** Next: add the header to the three GCP files (or scope the rule to physical hosts) and add a trivial `lib-invariants`-style grep for `Last reviewed:`.

3. **`docs/architecture.md:55-56`** — Rule 2 says `nix build '.#checks.x86_64-linux.invariants-<host>'` verifies "that unauthorized profiles haven't leaked into a host" (headless hosts inheriting GUI/Wayland). The generated baseline (`flake/checks.nix:262-271,677-681`) is stateVersion, `--reset`, registry pin, initrd tools, disko, plus registry assertions; nothing in `lib/invariants.nix` references `hyprland`, `xserver`, `pipewire`, or a desktop package (grep). `homeserver-gcp` importing `desktop.nix` would pass every invariant. **Verified.** Next: add a "non-desktop hosts have no desktop profile" invariant keyed on `hostMeta.homeManager.role != "desktop"`, or reword the rule.

4. **`docs/architecture.md:66`, `docs/security.md:268-269`, `lib/hosts.nix:7-8`** — All three say the ACL generator uses `tailnetFQDN` "for host-specific destinations when needed". `lib/acl.nix` never reads `tailnetFQDN`; it consumes only `tag` and `acceptFrom` and emits tag-to-tag rules by design (`:4-5,:50,:84-98`). **Verified.** Next: delete the claim in all three places (the registry header is the one that will mislead the next host addition).

5. **`docs/architecture.md:11-16`** — The layer table has no row for `modules/nixos/hardware/` (`displaylink.nix`, `nvidia-prime.nix`); they only appear as an aside in Rule 1 (`:43`). Trivial. Next: add a row or fold them into Layer 1.

## 2. `docs/operations.md` (and `scripts/validate.sh` usage text)

1. **`docs/operations.md:16-21`** — The Deployment Matrix lists `main`, `homeserver-gcp`, `mac`, `user@wsl`. `lib/hosts.nix:113-146` has `gcp-builder` and `gcp-agent`, both `status = "active"` with `deploy` entries (eval: `deploy.nodes` = `gcp-agent gcp-builder homeserver-gcp mac`), and `README.md:302-309` lists all six. **Verified.** Next: add both rows (builder: `deploy '.#gcp-builder'` after starting the VM; agent: reprovision / manual activation, no auto-activation).

2. **`docs/operations.md:210-217`** (also `:212` "manual deploy workflow", `:240-246`) — "The workflow is only for phase-1 homeserver deploys: it is `workflow_dispatch` only, requires the `confirm_target` input…". `.github/workflows/deploy-homeserver.yml:15-28,64-67` triggers on every `push` to `main` touching the homeserver closure; `confirm_target` is only required for dispatch. `hosts/homeserver-gcp/CLAUDE.md:60-64` and `docs/security.md:174` already describe auto-deploy, and `hosts/homeserver-gcp/github-runner.nix:14-16` still says "The deploy workflow is manual and main-branch gated." **Verified.** Highest-value doc fix in this report: the section describes a manual gate that no longer exists in front of a root-equivalent action. Next: rewrite as push = default, dispatch = escape hatch; fix the nix comment.

3. **`scripts/validate.sh:130`** — Usage text: `host <name>  Build one host closure: main-ci, main, homeserver-gcp, mac, installer`. `build_host` (`:147-182`) also accepts `gcp-builder`, `gcp-agent`, and `main-full`. **Verified.** Next: update the usage string (root `CLAUDE.md` and the runbooks are right).

4. **`docs/operations.md:362-365,373-375`** — The CVE workflow "scans the current flake-built `main` and `homeserver-gcp` closures". `scripts/validate.sh:344-359` deliberately scans `main-ci` (comment `:349-356`: the real `main` pulls the unfetchable DisplayLink blob). **Verified.** Next: say `main-ci` and note the ci-gated packages are outside the scan.

5. **`docs/operations.md:466-468`** — Offload is a no-op "whenever … `gcloud` is absent". `scripts/validate.sh:35-46` falls back to `nix shell nixpkgs#google-cloud-sdk -c gcloud`; the no-op condition is "neither `gcloud` nor `nix`", as `hosts/gcp-builder/CLAUDE.md:39-41` says. **Verified.** Next: align the wording.

6. **`docs/operations.md:407-410`** — Cites `home/users/user/mac.nix`'s `moonlight-qt.override { ffmpeg = ffmpeg_8; }` as the living example of a self-expiring override; `home/users/user/mac.nix:10-13` says the override is gone and plain `moonlight-qt` is used. The suggested grep (`:404`) has zero true hits today (one false positive at `hosts/gcp-agent/default.nix:187`, "drop this lock"). **Verified.** Next: rephrase as a past example.

7. **`docs/operations.md:93-94`** — "Sunshine runs as a Home Manager user service". It is the NixOS `services.sunshine` module (`hosts/main/default.nix:290`) whose generated user unit gets a `wantedBy` override at `:453-460`. **Verified.** Next: fix the wording.

8. **`docs/operations.md:170-179` + `scripts/validate.sh:372-383,396-400`** — tf-drift's stated job is to guard the homeserver resources that carry "apply manually" notes. `infra/main.tf:58-69` `google_compute_firewall.deny_internal_between_hosts` carries that note (`:56-57`), targets the homeserver tag, and is security-relevant (it re-blocks GCP's `default-allow-internal` between homeserver and builder), but it is not in the `-target` list, so a live deletion is invisible to the guard. **Verified.** Next: add `-target google_compute_firewall.deny_internal_between_hosts`; mention it in the doc.

9. **`docs/operations.md:295,301`, `hosts/homeserver-gcp/CLAUDE.md:114,188`** — Use `*.example.ts.net`, while `hosts/gcp-agent/CLAUDE.md:144,147,199`, `lib/hosts.nix:33`, and `.github/workflows/deploy-homeserver.yml:131` use the real `tail90fc7a.ts.net`. The sanitisation is inconsistent and the real name is already committed. **Verified, low.** Next: pick one convention (e.g. `$(nix eval --raw .#deploy.nodes.mac.hostname)`).

10. **`docs/operations.md:346-360`** — The Validation block omits `docs`, `tf-drift`, `profile-test <name>`, `package <name>`, and `smoke-homeserver-gcp`; the first two appear later (`:422,:424`), the rest only in "Rules of thumb". Trivial. Next: list every subcommand once or point at `validate.sh --help`.

11. **`docs/operations.md:304`, `hosts/mac/CLAUDE.md:65-79`** — The mac post-deploy check list (`tailscaled sshd thermald power-profiles-daemon`) omits `wpa-supplicant-wlp3s0` and `dhcpcd`, the units that actually carry the Mac's Wi-Fi (`hosts/mac/default.nix:73-74,246-277`), and the runbook's "Hardware Notes" never say that `wlp3s0` is NM-unmanaged and driven by a sops-delivered `wpa_supplicant.conf` (`:36-46,:290-295`). **Verified omission.** Next: add both units to the check list and a Wi-Fi paragraph to the runbook.

## 3. `docs/security.md` (remainder) and the binary-cache lib it describes

1. **`docs/security.md:34`** — "Planned Home Manager user-secret backups under `home/users/user/secrets/`". The directory holds five encrypted files consumed by `home/users/user/secrets.nix:45-65` (imported at `home.nix:321`), and `:54-58` and the inventory row `:147` treat them as current. **Verified.** Next: drop "Planned".

2. **`docs/security.md:77-79`** — Names the worked example `adguardhome_admin_password`; the secret is `adguard_admin_password` (`hosts/homeserver-gcp/adguard.nix:50`), as the inventory row `:133` correctly says. **Verified.** Next: fix the name.

3. **`docs/security.md:129-148`** — The inventory omits `gcp_builder_build_key` (two independently revocable copies: `hosts/main/nix-remote-build.nix:20-24`, `hosts/gcp-agent/nix-remote-build.nix:30-35`) and `luks_keyfile` (`hosts/mac/default.nix:296-300`). Rotation for the builder key exists only in `hosts/gcp-builder/CLAUDE.md:151-160` and covers main's copy only. Row `:131` also says `user_password` is on "all" hosts; `gcp-builder` has no sops and `gcp-agent` declares none (`hosts/gcp-agent/default.nix:286-306`; runbook `:365` "No console password"). **Verified.** Next: add both rows (kind: self; see §5.7 for the recipe) and correct "all" to `main`,`mac`,`homeserver-gcp`.

4. **`docs/security.md:454-469`** — "Deploy And Bootstrap Sudo" lists `mac` and `homeserver-gcp`; `hosts/gcp-builder/default.nix:26-29` also sets `wheelNeedsPassword = false` (root `CLAUDE.md` Security Preferences lists all three; `lib/invariants.nix:694-698` enforces it for deploy targets). **Verified.** Next: add the builder bullet, noting it is additionally root-equivalent via remote builds.

5. **`docs/security.md:293-297,369-377`, `lib/binary-cache.nix:9,15-16`** — "Two hosts (`main`, `mac`) trust R2 … a separate pair (`homeserver-gcp`, `gcp-builder`) trust `main.local`". `gcp-agent` trusts **both** edges (`hosts/gcp-agent/default.nix:52-63`) and hard-codes the `cache.nixos.org`/`main.local` literals instead of reading `lib/binary-cache.nix` — contradicting `:298-300` ("defined once … a key rotation starts by editing that file"; a `main.local` rotation would miss the agent). Eval: gcp-agent `trusted-public-keys` = `[cache.nixos.org ×2, main.local]`, `extra-trusted-public-keys` = `[nix-cache-1]`. **Verified.** Next: consume `binaryCache.*` in gcp-agent; list it in the doc and the lib comment.

6. **`lib/binary-cache.nix:6-7`** — Says `scripts/check-cache-config.sh` checks the action "against hosts/main/default.nix". The script compares `.github/actions/setup-nix/action.yml` with `lib/binary-cache.nix` (`check-cache-config.sh:20-29`); `hosts/main/default.nix` is not read. **Verified.** Next: fix the comment (the doc at `:361-362` is right).

7. **`lib/binary-cache.nix:17` + `hosts/{homeserver-gcp,gcp-builder,gcp-agent}/default.nix` `trusted-public-keys`** — NixOS already trusts `cache.nixos.org-1` by default; eval shows the key listed twice on all three GCP hosts. `cacheNixosOrgPublicKey` exists only to re-add a default. Dead config in a shared lib. **Verified (eval).** Next: drop the constant and the three entries, or move those hosts to `extra-trusted-public-keys = [ mainLocalPublicKey ]`.

8. **`docs/security.md:507`** — `audit_event_type` is "currently `sudo`, `ssh`, or `service_failure`"; `hosts/homeserver-gcp/default.nix:133-138` adds an `http` stream (`nginx` access log, JSON) through `extraSources` — exactly the extension point `:519-521` describes. **Verified, minor.** Next: mention `http` as the host-local example.

9. **`docs/security.md:264-265`** — "approved inbound TCP ports per source tag" vs `lib/hosts.nix:11` "(TCP+UDP)". Generated `tag:X:port` rules are protocol-agnostic and the registry carries UDP-only intents (Sunshine 47998-48002, Syncthing 22000). **Verified, minor.** Next: "ports (TCP and UDP)".

10. **`docs/security.md:316-319`** — Job names `light`/`package`; `.github/workflows/nix.yml:112,200` are `checks-light`/`packages`. Trivial.

11. **`docs/security.md:669`** — `nix develop#security`; the installable is `nix develop .#security` (`flake/dev.nix:174`). Trivial.

12. **`docs/security.md:85-106`** — Host Key Rotation covers SSH-derived hosts and homeserver-gcp's pre-baked key, but `mac` and `gcp-agent` use the same pre-baked pattern (`hosts/*/secrets/ssh_host_ed25519_key*.enc`; `flake/checks.nix:648-662,693-695` generates a sops-bootstrap check for all three). **Verified omission.** Next: generalise the paragraph to "pre-baked hosts (`homeserver-gcp`, `mac`, `gcp-agent`)".

## 4. Shared modules (`modules/nixos/profiles/*`, `modules/nixos/services/*`)

1. **`modules/nixos/profiles/desktop.nix:67-74`** — `security.pam.services.greetd.enableGnomeKeyring = true` is a no-op. The pinned nixpkgs greetd module sets `useDefaultRules = false` with explicit rules that delegate to `login` (`<nixpkgs>/nixos/modules/services/display-managers/greetd.nix:79-87`); eval of `security.pam.services.greetd.text` on `main-ci` is four lines (`account include login`, `auth substack login`, `password substack login`, `session include login`) with no `pam_gnome_keyring`. The keyring hooks reach the greeter through `login`, which `services.gnome.gnome-keyring.enable` sets on its own (`gnome-keyring.nix:38`; eval of `login.text` shows the three keyring lines). Same shape as main-audit Correctness #7 (`fprintAuth`). Affects `main` and `mac`. **Verified via eval + nixpkgs source.** Next: delete line 74; reword the comment to say `login`'s stack carries it.

2. **`modules/nixos/profiles/observability/default.nix:99`** — The public `observability-stack` module defaults Grafana's home dashboard to `/etc/grafana-dashboards/main-machine.json`, a dashboard only `hosts/homeserver-gcp/dashboards.nix:549-772` defines; the shared `dashboards.nix` pre-registers `fleet` (`:302-305`) and `security-events` (`:307-310`) only. Inside this repo the value is dead (homeserver `mkForce`s `overview.json`, `grafana.nix:61-63`; eval confirms `overview.json`); for an external adopter the default names a file that will not exist. **Verified.** Next: default to the shared `fleet` dashboard (and enable it by default), or make the option `null` and let Grafana pick.

3. **`modules/nixos/profiles/observability/dashboards.nix:276-281`** — Option description: "The built-in `fleet` dashboard is pre-registered"; `security-events` is too (`:307-310`). Trivial. Next: update the text.

4. **`modules/nixos/services/systemd-failure-notify.nix:15,22,30-41`** (fleet-wide extension of main-audit Correctness #2) — Under `set -euo pipefail`, the `systemd-cat` pipe at `:22` runs **before** the webhook `curl` at `:30`. When `systemd-cat` execs the missing `/bin/cat` (verified live on `main` by the prior audit) the script aborts, so the webhook is never posted. On `homeserver-gcp` the "direct failed-unit webhook fallback" (`hosts/homeserver-gcp/default.nix:190-201`; runbook `:142-148`) is therefore also dead, and the invariant `alerting stack has direct failed-unit webhook fallback` (`flake/checks.nix:314-342`) asserts wiring that cannot deliver. **Verified by reading; homeserver runtime effect plausible** (same store path, no live access). Next: fix the module first (`systemd-cat -t … -p warning ${coreutils}/bin/echo "$MESSAGE"`, or `logger`), then add the VM test from main-audit Coverage #1.

5. **`modules/nixos/profiles/observability/collectors.nix:507-521`** — `enabledCollectors` hard-codes `powersupplyclass` (laptop-only) in the shared profile, so `hosts/homeserver-gcp/default.nix:294-306` must `mkForce` the entire list to drop one entry, and every future server host will copy that block. **Verified.** Next: expose `collectors.metrics.nodeCollectors` (list, defaulting to today's set) or move `powersupplyclass` into `desktop.nix`.

6. **`modules/nixos/profiles/sops-base.nix:8,14-15`** — Header: "all hosts set defaultSopsFile and declare secrets". `gcp-builder` imports it with no sops at all (registry `sops = false`; `hosts/gcp-builder/default.nix:18`) solely for the `users.users.user.openssh.authorizedKeys.keys` line — SSH-key policy living in the sops profile. **Verified.** Next: move the authorized-keys line into `user.nix` (or `machine-common.nix`); fix the header.

7. **`modules/nixos/profiles/server-common.nix:3-10` vs `hosts/gcp-agent/default.nix:84-93,64-69,42-43`** — gcp-agent duplicates the terminfo block verbatim (same four packages, same comment) instead of importing `server-common.nix`; re-declares `nix.gc` identically to `base.nix:21-25`; and re-sets `boot.zfs.forceImportRoot = false`, which `base.nix:11` already does via `mkDefault`. **Verified.** Next: import `server-common.nix`; delete the two duplicates.

8. **`modules/nixos/profiles/base.nix:9-11`** — "Set the upcoming 26.11 default explicitly … to avoid evaluation-time warnings." On the pinned nixpkgs (`system.nixos.release` = 26.11) the default is `lib.versionOlder config.system.stateVersion "26.11"` (`zfs.nix:355-358`), i.e. still `true` for every host here (all `stateVersion = "24.11"`), and the warning at `zfs.nix:700-710` is exactly what the explicit `false` silences. The setting is correct and remains load-bearing until stateVersions move; only "upcoming" is stale. **Verified.** Next: reword to "explicit `false`; the 26.11 default applies only to stateVersion ≥ 26.11".

9. **`modules/nixos/profiles/base.nix:36-45`** — nix-daemon `Nice=10` / `CPUWeight=50` / `IOWeight=50` is justified as "bias scheduling away from interactive desktop processes" but is applied fleet-wide; eval shows the same values on `gcp-builder`, whose own config says "This box exists to build; let it use the whole VM" (`hosts/gcp-builder/default.nix:60-61`). No practical harm on an otherwise idle builder, but the profile's rationale and the builder's intent contradict. **Verified (eval).** Next: move the bias to `desktop.nix`, or `mkDefault` it so servers can reset.

10. **`modules/nixos/profiles/security.nix:32-33`, `machine-common.nix:3-6`, `hosts/gcp-agent/default.nix:96-99`** — `services.openssh.enable = lib.mkDefault false` is overridden on all five hosts (eval: all `true`); `machine-common.nix` enables it unconditionally for the four hosts that import it, and gcp-agent re-enables it a third time. The secure default is fine for the public `profiles-security` export; the gcp-agent lines are dead. Trivial. Next: drop the gcp-agent block.

11. **`hosts/mac/default.nix:174-179`, `hosts/mac/CLAUDE.md:76-77`** — mac's `IdleAction=suspend` under Hyprland has the same problem as main-audit Correctness #9 (no session `IdleHint`); hypridle in the shared desktop role (`home/users/user/home.nix:415`) is what actually suspends, yet the runbook documents the logind path as the mechanism. **Plausible** (same reasoning as main; not observed). Next: apply whatever fix main gets, to both.

## 5. Host runbooks and root `CLAUDE.md` cross-references

1. **`hosts/gcp-agent/CLAUDE.md:9-10`** — "Status: **provisioning**". `lib/hosts.nix:138` (the declared SSoT) says `status = "active"`, `README.md:114` agrees, and the memory notes say the v2 loop has shipped. **Verified.** Next: set to active.

2. **`hosts/gcp-agent/CLAUDE.md:41-43`** — "The Home Manager `agent` role therefore sets `userSecrets.enable = false` (`home/users/user/agent.nix`)." `agent.nix` never sets it; it simply does not import `secrets.nix` (header `:4-12`). `home/users/user/mac.nix:6` is the file that sets `userSecrets.enable = false`. **Verified.** Next: fix the sentence.

3. **`hosts/gcp-agent/CLAUDE.md:227-233,282-301` vs `docs/operations.md:427-455`** — The agent runbook says "v1 is attended: it opens PRs but never merges" (matching `scripts/agent-run-issue.sh:78,1327`) and never mentions a review/merge stage; operations.md says "The gcp-agent issue loop can autonomously merge low-risk PRs". `agent-run-issue.sh` never calls `agent-review-pr.sh` or `agent-merge-gate`, and no workflow or `agent-session.sh` path invokes them (grep), so today the merge stage is a separate operator-invoked command (`scripts/agent-review-pr.sh --pr <n> --enable-auto-merge`), not part of the loop. **Verified.** Next: either wire the review stage into the loop, or reword operations.md to "a separate, operator-invoked review step" and add a pointer in the agent runbook.

4. **`hosts/homeserver-gcp/CLAUDE.md:108-111`** — "unless `grafanaTailscaleRoleMap` in `default.nix` promotes specific logins". No such identifier exists; the role map is the hard-coded `ROLE_MAP_JSON = builtins.toJSON { }` in `hosts/homeserver-gcp/grafana.nix:27` (parsed at `grafana-tailscale-auth/main.go:68-70`). **Verified.** Next: point at `grafana.nix` and show the JSON shape.

5. **`hosts/mac/CLAUDE.md:56-63`** — The `hosts/mac/impermanence.nix` list omits `/var/lib/fail2ban` (`impermanence.nix:20`). **Verified.** Next: add it.

6. **`hosts/mac/CLAUDE.md:16-17` vs `:92-95`** — Line 16 labels `nh os switch` as "Local rebuild (slower; build runs on the Mac)", implying `deploy '.#mac'` builds elsewhere; `:92-95` and `flake/deploy.nix:42` (`remoteBuild = true`) say deploy also builds on the Mac, so the contrast is wrong and the advice to "prefer `nh os switch` on the Mac for heavy changes" buys nothing. **Verified.** Next: state that both paths build on the Mac; the real speed lever is the R2 substituter (`hosts/mac/default.nix:133-136`).

7. **`hosts/gcp-builder/CLAUDE.md:151-160`, `hosts/gcp-agent/CLAUDE.md:147-150,309-313`** — The build-key rotation recipe chains `ssh-keygen` → `sops -e … > file` → `shred -u` as separate top-level commands, exactly the pattern root `CLAUDE.md` "Secrets" forbids after it destroyed a key (0-byte output when `sops` is off `PATH`, then `shred`). The agent runbook's credential capture (`ssh … | sops -e … > file`) has the same failure shape (no shred, so lower stakes). Neither runbook rotates the agent's own copy of the build key, although `gcp-agent/CLAUDE.md:309` links to the builder section for "shared mechanics" and `hosts/gcp-builder/default.nix:207` authorises it. **Verified.** Next: rewrite both as one `nix develop -c bash -c 'set -euo pipefail; trap … EXIT; …'` block and cover both keys.

8. **`hosts/homeserver-gcp/CLAUDE.md:8-18`** — The Services list omits the homepage/status surface (`status-page.nix`: `homepage-status.timer`, `homepage-status-events.service` on `127.0.0.1:9273`, nginx `/home/*` routes at `nginx.nix:149-208`) and the daily `lynis-audit` (`audits.nix`), both of which feed the Overview dashboard and `/home/status.json`. **Verified omission.** Next: add two bullets.

9. **`hosts/homeserver-gcp/CLAUDE.md:60-62`** — The path-filter summary omits `scripts/validate.sh` and `scripts/check-host-drift.sh` (`deploy-homeserver.yml:25-26`). Trivial.

Root `CLAUDE.md` cross-links all resolve: the five host runbooks, the `.claude/skills -> ../.agents/skills` symlink, the three guard hooks, `.codex/config.toml`, `home/files/agents/global-development.md`, `flake-update.yml`, `collectors.nix`'s attribute-level `mkIf` on `exportSystemMetadata` (`:615`), and the `obs` node in `tests/nixos/profile-observability.nix:21-27` that does not enable `collectors.metrics`. The runbook anchors used (`docs/security.md#secret-rotation-ritual`, `hosts/gcp-builder/CLAUDE.md#build-key-rotation`) match real headings.

## 6. `README.md`

1. **`README.md:26-35,224-266,359-394`** — "Reusable Outputs" and "Flake Outputs" omit the `lib` flake output (`flake.nix:229-239`: `lib.acl`, `lib.dashboards`, `lib.generators`, with boundary tests and `docs/modules/lib-helpers.md`), and the Documentation section links neither `docs/modules/lib-helpers.md` nor `docs/key-escrow.md` (reachable only from `docs/security.md:51`). **Verified.** Next: add a row and two links.

2. **`README.md:275-290`** — The layout omits `examples/` (`examples/mini-fleet`, exercised by `flake/checks.nix:587-646` and described in `docs/public-adoption.md`). **Verified.** Next: add a line.

3. **`README.md:338-340`** — "booted NixOS tests and CVE reports live under `legacyPackages`". `flake.nix:222-224` exposes only `legacyPackages.<system>.ciTests`; CVE reports come from `scripts/validate.sh cve-reports` running `vulnix` outside Nix (`:344-370`). **Verified.** Next: drop "and CVE reports".

4. **`README.md:233-238`** — The package list omits `drift-inventory-data` (`flake/dev.nix:111-119`, consumed by `scripts/check-host-drift.sh:46`) and the lint re-exports (`statix`, `deadnix`, `shellcheck`, `lazyactions`, `:95-100`) that `docs/operations.md:559` relies on (`nix run .#statix`). **Verified, minor.** Next: list `drift-inventory-data`; one line for the re-exports.

5. **`README.md:6-7`** — The intro names four roles and omits the agent host that the diagram (`:80`) and table (`:114`) include. Trivial.

## 7. Test / invariant coverage gaps (new; not in the 09-17 report)

1. No check enforces the hardware-configuration header policy (§1.2). Cheap grep-style `lib-invariants` entry.
2. No check enforces headless closure integrity despite `docs/architecture.md:55-56` claiming one (§1.3).
3. No check that every non-default `trusted-public-keys`/`extra-trusted-public-keys` entry across hosts originates in `lib/binary-cache.nix` (§3.5/§3.7) — would have caught gcp-agent's literals.
4. **`scripts/check-doc-links.sh:70-77`** validates file targets only: a bare `#anchor` returns early and a `file.md#anchor` link is checked with the fragment dropped, so heading renames (e.g. the two runbook anchors in §5) are never caught. **Verified.** Next: slugify headings and validate fragments.
5. `flake/checks.nix:314-342` asserts webhook wiring without exercising delivery (§4.4); the VM test proposed in main-audit Coverage #1 closes both.

---

## Checked and fine

- `bash scripts/validate.sh flake-eval` passes on `1394e6d`; the only warning is deploy-rs's `unknown flake output 'deploy'`.
- `.sops.yaml` recipient groups match `docs/security.md:11-19` and the per-host path rules; sops-bootstrap checks are generated for `homeserver-gcp`, `mac`, `gcp-agent` (`flake/checks.nix:693-695`), consistent with `gcp-builder`'s `sops = false`.
- Backup classes in `docs/security.md:544-551` match `lib/backup-policy.nix`, which `homeserverGcpB2BackupUsesCriticalPolicy` also reads.
- `hosts/homeserver-gcp/CLAUDE.md`: Vaultwarden `:8222`, AdGuard `:13001`/`:3001`/state paths, restic paths and excludes, canary and drill metric names and the ~100 d `RestoreDrillStale` threshold, heartbeat 3 min cadence, failure-notify unit list, runner labels, 30 s confirm timeout (mac gets 60 s, `flake/deploy.nix:16-18`), `Restart=always`/`RestartSec=10` for `adguardhome` (eval), `tailscale-cert.timer` daily (eval), 50 GB disk, systemd-boot, the runner-GC recovery (backed by the `homeserverDeployRunnerRegistrationGcRunbookMatchesConfig` invariant), and the memory-containment rule.
- `hosts/gcp-builder/CLAUDE.md`: `n2-standard-4`, 20 min idle / 5 min check / 10 min first check, `/var/lib/tailscale-authkey` with shred-after-join, `accept-new` on both callers, no `nix.buildMachines` anywhere, both build keys authorised, nested-virt and `desired_status` handling in `infra/builder.tf`.
- `hosts/gcp-agent/CLAUDE.md`: `e2-standard-4`, 60 min idle / 15 min first check / four activity conditions, the secret file set, `gh auth git-credential` helper, no `service_account` in `infra/agent.tf` or `builder.tf`, `gcloud` absent from base packages, the narrow-sudo invariant name.
- `hosts/mac/CLAUDE.md`: disk by-id equals the registry (`disko.nix:9` reads `hostMeta.hardware.diskById`), LUKS keyfile via `boot.initrd.secrets`, `canTouchEfiVariables = false`, lid settings, `permittedInsecurePackages` for broadcom, no backup class, `remoteBuild = true`.
- `docs/operations.md`: drift-check facts and the 5×3 s retry, `drift-inventory-data` / `/etc/host-drift-inventory.json`, GCE snapshot labels/retention/locations (`infra/variables.tf` defaults), ACL-drift workflow triggers (push-apply plus scheduled detect-only), `nix.nixPath`, dev-shell `shellHook` and commit-msg hook, the `.agents/learning/candidates/archive/2026-06-06-…` file, the `input-main`/`input-server`/`moon-main` aliases (split across `mac.nix` and `main.nix`), and the homeserver smoke-test assertions (`/`, `/grafana/`, exact `/obs/*` pushes with and without auth, broader `/obs/*` denied, both blackbox probes).
- `docs/security.md`: R2 URL/key match `lib/binary-cache.nix` and `.github/actions/setup-nix/action.yml`; Shielded VM flags in `infra/main.tf:136-140`; ingest paths; blackbox probes; protected paths match `.agents/governance.yaml`; audit-stream labels and built-in selectors; every `rotate-secret.sh` subcommand named exists; port 2222 / recovery keys / `initrd_ssh_host_ed25519_key` on main.
- `README.md`: the four apps, the `nixosModules`/`homeModules` lists, both dev shells, sample artifacts and the `#sample-artifacts` anchor, every Documentation link, `x86_64-linux`-only.
- `modules/nixos/services/hardened.nix` matches its own comment block and `docs/modules/services-hardened.md` (forced-key set, `relaxBase`, null rejection); `observability-client.nix` defaults match the nginx ingest paths.

Suggested triage order: §4.4 (webhook fallback dead fleet-wide), §2.2 (auto-deploy documented as manual), §2.8 (tf-drift blind spot), §4.1 (dead PAM setting on two hosts), §3.5–3.7 (binary-cache trust drift), §5.7 (key-destroying rotation recipe), then the doc sweep in file order.
