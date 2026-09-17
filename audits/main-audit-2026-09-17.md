# `main` host audit — 2026-09-17

Read-only audit of `hosts/main/**`, its runbooks, the shared profiles it imports, its home-manager entry, and the invariants/tests that cover it. No files were changed. Live checks ran as `user` on `main` (no sudo). `bash scripts/validate.sh flake-eval` passes; the running system (`26.11.20260910.8ce4ef6`) matches the current `flake.lock`.

Live state that colours several findings (verified via `systemctl`/`journalctl`/CLI):

- Tailscale has been in the `Stopped` state since `sudo tailscale down` on 2026-08-19 01:30. `tailscaled` runs, but nothing has left `main` for homeserver-gcp (metrics, logs, traces) for a month, and nothing detected that.
- `restic-check-local.service` and `notify-failure@restic-check-local.service` are both in `failed` state right now.
- `timedatectl` reports `NTPSynchronized=no`; timesyncd has never contacted a server in the persisted journal (since 2026-05-16).
- Kernel reports "Running old microcode" and two CPU vulnerabilities as `Vulnerable: No microcode`.

Confidence labels: **verified** (live check, eval, or upstream source read), **plausible** (strong inference, not directly observed), **speculative**.

---

## 1. Doc/code drift

1. **`docs/security.md:574-581`** — Describes the abandoned "destination-specific policy rules at pref 114" mechanism for Mullvad/Tailscale coexistence. Code (`hosts/main/networking.nix:29-51`) explicitly deletes leftover pref 120/117/114/111/50 rules and instead injects `100.64.0.0/10 dev tailscale0` into the main table; live `ip route`/`ip rule` confirm the route-injection design (Mullvad's `lookup main suppress_prefixlength 0` is at pref 5208 today). `docs/security.md:567-572` also says the kill switch checks the packet mark `0x6d6f6c65`, while the code comment and `hosts/main/CLAUDE.md:204-206` say the conntrack mark `0x00000f41` is what Mullvad's output chain checks. **Verified.** Next: replace the section with the `hosts/main/CLAUDE.md:195-222` text, which is accurate.

2. **`docs/security.md:649-652`, `.claude/main/anonymous.md:13-16`** — Both promise the anonymous boot "auto-connects + explicit-connects" Mullvad so it is never "locked-down-but-disconnected". `hosts/main/anonymous.nix:57-61` deliberately drops `/etc/mullvad-vpn` from the persisted set, so the daemon boots logged out (see Correctness #4). **Verified contradiction in the sources; runtime effect plausible.** Next: fix whichever side is wrong after deciding the design.

3. **`docs/operations.md:124-127`** — States the prometheus/alloy shutdown hang was "fixed with `TimeoutStopSec = "10s"`". Live: both units were still SIGKILLed on the last switch (2026-09-13 18:15:44, `State 'stop-sigterm' timed out. Killing.`); 18 and 17 such events in the persisted journal. The setting bounds the delay; it does not stop the hang (prometheus blocks in "Stopping remote storage…" because the remote endpoint is unreachable while Tailscale is down). `opentelemetry-collector` keeps the 90 s default although `collectors.nix:634-639` says "both units" ship over the same path. **Verified.** Next: reword the doc, and see Stale workarounds #5 for a real fix.

4. **`hosts/main/CLAUDE.md:221-222`, `docs/security.md:588-589`** — "all three mechanisms are removed" in the anonymous specialisation. The `tailscale-mullvad-compat` nftables table (`networking.nix:95-103`) is not overridden anywhere in `anonymous.nix`; eval confirms it stays. Harmless (no `tailscale0`), but the claim is false. Also `CLAUDE.md:228` says the three mechanisms live in `default.nix`; they live in `networking.nix`. **Verified.** Next: correct both sentences.

5. **`hosts/main/default.nix:292-296`** — Comment warns the `systemd.user.services.sunshine.wantedBy` override "must stay in sync with autoStart or this setting is a no-op". The override at `default.nix:458-460` already derives from `config.services.sunshine.autoStart` (eval: `wantedBy = []`). **Verified.** Next: delete the stale warning.

6. **`hosts/main/networking.nix:91`** — "accepted by Mullvad's policy routing bypass at rule 113"; the same file (lines 29-33) says Mullvad's pref numbers move, and live it is 5209. Also, the `meta mark` is set in the output hook keyed on `oifname tailscale0`, i.e. after routing already chose `tailscale0`, so the fwmark half of the rule cannot influence routing; only the ct mark does the filter work. **Verified live.** Next: fix the comment; optionally drop the redundant `meta mark`.

7. **`.claude/main/displaylink.md:9-11`, `:78-79`** — Points to a "hosts/main/CLAUDE.md → external monitor notes" section that does not exist (only the runbook pointer at `CLAUDE.md:167-175`), and says the catch-all monitor line is `,preferred,auto,1`; `home/files/hypr/hyprland.conf:27` is `,highrr,auto,1`. The pinned blob (6.2.0-30, `displaylink-620.zip`, `sha256-JQO7…`) **matches the current nixpkgs pin** (eval). **Verified.** Next: fix the two references.

8. **`hosts/main/CLAUDE.md:75-91`** — Persistence taxonomy omits `/var/lib/prometheus2` (static `prometheus` user, TSDB + remote-write WAL, lost per boot) and misfiles `/var/lib/NetworkManager` (its `secret_key` is random per boot, not "declaratively regenerated"). It also declares `/var/lib/node-exporter-textfiles` intentionally ephemeral; see Persistence #1 for why that decision is wrong. **Verified.** Next: add both paths to the right category once decided.

9. **`hosts/main/CLAUDE.md:14,109`, `.claude/main/usbguard.md:52`, `hosts/main/impermanence.nix:24`, `docs/operations.md:32`, `README.md:304`** — Every rebuild instruction is `nh os switch --hostname main .`; none mentions `sudo nixos-switch-main` (`default.nix:41-58`), which is the only path that works without a TTY password and is what agents actually use. **Verified.** Next: mention the wrapper once in `hosts/main/CLAUDE.md` Quick Reference.

10. **`hosts/main/CLAUDE.md:130-141`** — The "manual verification" block is presented as agent-runnable via the NOPASSWD allowlist, but `sudo btrfs subvolume list /.btrfs-root` is not in it (live `sudo -l` matches the code exactly). Trivial. Next: note that line needs a password.

## 2. Correctness

1. **`hosts/main/backups.nix:124-133`** — `restic-check-local` has failed on every scheduled run since 2026-06-15 (06-15, 08-10, 08-17, 08-24, 09-01, 09-10, 09-14 …; last success 2026-06-08). The failing step is the `ExecStartPre` probe introduced that day ("B2 repo unreachable after ~5min"), while `restic-backups-local` succeeds against the same repository and credentials (today 22:57). Each failing run shows ~730 KB inbound traffic, so B2 answers; the probe gets an error, not a timeout, and `>/dev/null 2>&1` hides it. The 2026-05-18 run (pre-probe) failed with `b2_download_file_by_name: 403` on `Stat(<config/>)`, so a B2 403 (download cap or key restriction) is the leading suspect. Result: no integrity check for three months, and the `ResticCheckStale` alert never fired (see Persistence #1). **Verified via journal.** Next: run the probe as root with stderr visible; make the probe log stderr to the journal; consider dropping the probe and letting the check itself fail loudly with `Restart=on-failure`.

2. **`modules/nixos/services/systemd-failure-notify.nix:22,40`** — The notifier pipes into `systemd-cat` with no command. `systemd-cat` then `exec`s `/bin/cat`, which does not exist on NixOS (`/bin` contains only `sh`): "Failed to execute process: No such file or directory". With `set -e` the script dies there, so every `notify-failure@*.service` fails (all five restic-check failures since 08-17 show this) and `journalctl -t systemd-failure-notify` is empty. The other two channels are also dead on main: `webhookUrlFile` is `null` (eval), and the desktop branch (`:46-49`) tests `DISPLAY`/`WAYLAND_DISPLAY`, which a system unit never has. **Verified.** Next: `systemd-cat -t … -p warning ${coreutils}/bin/echo "$MESSAGE"` (or `logger`); set a webhook on main; deliver desktop notifications from a user unit that follows the journal tag.

3. **`hosts/main/default.nix:273-281` + `modules/nixos/profiles/impermanence-base.nix` (interaction)** — NTP has never synchronised. `boot.initrd.network.enable` runs systemd-networkd in the initrd (`boot.initrd.systemd.network.enable = true`, eval), which writes `/run/systemd/netif/state` with `OPER_STATE=off CARRIER_STATE=off`. `/run` survives switch-root, stage 2 has no networkd (`systemd.network.enable = false`, unit `not-found`), so the file is never updated. systemd's `network_is_online()` returns false when the state file exists with carrier off (upstream `network-util.c`, read), so timesyncd waits forever: `Packet count: 0`, zero "Contacted time server" lines since 2026-05-16. **Verified end to end.** Next: delete `/run/systemd/netif` in the initrd after networkd stops (extend `flush-network-before-stage2`, ordered after networkd), or switch to chrony; add the `timex` node_exporter collector and a sync alert.

4. **`hosts/main/anonymous.nix:57-61,153-170`** — The anonymous boot cannot connect Mullvad. `/etc/mullvad-vpn` (account, device key, settings) is intentionally not bind-mounted, so the daemon starts logged out; `mullvad-lockdown` then turns lockdown on and `mullvad connect || true` silently fails. Every anonymous boot is offline until a manual `mullvad account login <number>`, which also registers a new device each time (Mullvad's 5-device cap) unless logged out before reboot; Tor (`:98-101`) cannot bootstrap through the kill switch either. **Plausible** (cannot boot the spec read-only; grounded in Mullvad's state layout and the lockdown semantics). Next: decide between (a) persisting a dedicated anonymous-only Mullvad state dir, (b) accepting manual login and documenting it, or (c) lockdown-off-until-login; then fix docs (Drift #2).

5. **`hosts/main/networking.nix:82`** — `networking.nameservers = [ "127.0.0.53" ]` renders `DNS=127.0.0.53` into `/etc/systemd/resolved.conf`, making resolved's own stub its global upstream. resolved silently discards it (`resolvectl status` Global lists no DNS servers), and `/etc/resolv.conf` already points at the stub because `services.resolved.enable` is set. Dead, misleading config. **Verified live.** Next: delete the line.

6. **`hosts/main/default.nix:132-194`** — A 60-line `mkForce` block disables libvirt 12.7's secret-at-rest encryption (upstream `virt-secret-init-encryption.service` + `LoadCredentialEncrypted`, shipped by the libvirt package, not a NixOS option, so there is no clean toggle) and writes `encrypt_data = 0`. There is no comment explaining why. Most likely cause: `systemd-creds` encrypts with `/var/lib/systemd/credential.secret`, which lives on the ephemeral root (confirmed absent from `/var/lib/systemd`), so the persisted encrypted key becomes undecryptable after a rollback boot. **Effect verified; cause plausible.** Next: try persisting `credential.secret` as a `files` entry and dropping the block (libvirt secrets then get encrypted at rest); at minimum document the reason.

7. **`hosts/main/default.nix:219-222`** — `security.pam.services.greetd.fprintAuth = true` is a no-op: `/etc/pam.d/greetd` is `auth substack login` (the greetd module owns the text). Fingerprint at the greeter works only because `/etc/pam.d/login` carries `pam_fprintd`. **Verified live.** Next: drop the greetd line or comment that `login` provides it.

8. **`hosts/main/backups.nix:41,49`** — `/home/user/.mozilla/firefox` (profile moved to `~/.config/mozilla/firefox`, `home/profiles/desktop.nix:68`) and `/home/user/.local/share/kwalletd` (no KDE/KWallet anywhere in the home config; KeePassXC + gnome-keyring are used) do not exist on disk. `hosts/main/CLAUDE.md:118` still lists "KWallet". **Verified.** Next: remove both.

9. **`hosts/main/default.nix:321-325` vs `home/users/user/home.nix:410-437`** — Two idle-suspend policies: logind `IdleAction=suspend/15min` and hypridle's 900 s suspend, whose comment claims "single source of truth". logind's IdleAction needs a session `IdleHint`, which Hyprland does not set, so the logind path is likely inert. **Plausible.** Next: keep hypridle, drop `IdleAction`, fix the comment.

10. **`hosts/main/anonymous.nix:127`, `docs/security.md:638`** — `kernel.perf_event_paranoid = 3` is not a mainline value; the kernel documents -1/0/1/2 and treats everything ≥2 identically, and the live default is already 2. The setting changes nothing. **Verified against kernel docs and live `sysctl`.** Next: use 2 (or drop) and fix the docs table.

11. **`hosts/main/default.nix:53`** — `git config --global --add safe.directory` appends a duplicate entry on every `nixos-switch-main` run (harmless because `/root` is ephemeral). Trivial. Next: use `--replace-all` or guard with `--get`.

## 3. Security

1. **`hosts/main/hardware-configuration.nix` (whole file)** — Intel microcode loading is off: `hardware.cpu.intel.updateMicrocode` evaluates to `false` (the hand-maintained file dropped the generated `updateMicrocode = mkDefault enableRedistributableFirmware` line; `not-detected.nix` does not set it). Live kernel log: `x86/CPU: Running old microcode`, `SRBDS: Vulnerable: No microcode`, `MMIO Stale Data: Vulnerable: … no microcode` (i7-10750H, revision 0xea). **Verified live + eval.** Next: set `hardware.cpu.intel.updateMicrocode = true`; add an invariant for physical x86 hosts (Coverage #3). Highest-priority item in this report.

2. **`home/users/user/home.nix:117-131`** — The `codex` and `claude` wrappers run `npm exec --yes --package …@latest` on every invocation and pass `--dangerously-bypass-approvals-and-sandbox` / `--dangerously-skip-permissions` unconditionally. Any compromised npm release runs with full user autonomy on the primary workstation; the repo's guard hooks only apply inside this repo. **Verified by reading.** Next: pin versions (or use the nixpkgs packages) and move the bypass flags to per-repo settings.

3. **`hosts/main/default.nix:353-447` (scope of `services.hardened`)** — Only thermald, power-profiles-daemon, fwupd and bluetooth are sandboxed. Live `systemd-analyze security`: `dlm` 9.6 (proprietary DisplayLinkManager blob, root, unrestricted network), `libvirtd` 9.6, `tailscaled` 9.6, `mullvad-daemon` 9.6, `greetd` 9.8, `restic-backups-local` 9.2, `btrbk-local` 9.2, `alloy` 8.2, `opentelemetry-collector` 8.1, `nix-daemon` 9.6, `sshd` 9.6. **Verified.** Next: start with `dlm` (`RestrictAddressFamilies=AF_UNIX AF_NETLINK`, `ProtectSystem=strict`, `DeviceAllow` for evdi/USB) and the two backup jobs (`ProtectSystem=strict` + read-only paths; `PrivateNetwork` for btrbk).

4. **`hosts/main/default.nix:553-559,561-574,582-584`** — Internal devices (BT `8087:0026`, fingerprint `06cb:00be`, webcam `13d3:56b2`) and the four GenesysLogic hub IDs are allowed by VID:PID alone, so a BadUSB spoofing one of those IDs with a HID interface on an external port is accepted. Live `usbguard list-devices` shows all three internal devices report `with-connect-type "hardwired"`, narrow interface sets (`0e:01:00/0e:02:00`, `e0:01:01`, `ff:00:00`) and a fingerprint serial `86d072714e26`. **Verified.** Next: add `with-connect-type "hardwired"` plus `with-interface` (and the serial) to those rules; constrain hubs to `09:00:00`. Also review `IPCAllowedUsers` (`:537-540`): `user` can `usbguard allow-device` at runtime; `IPCAccessControlFiles` can make it list-only.

5. **`hosts/main/networking.nix:107-117`** — resolved keeps NixOS's default `FallbackDNS` (1.1.1.1, 8.8.8.8, 9.9.9.9 …; live `resolvectl status`), and the Wi-Fi link's DHCP resolvers are configured. In the normal boot Mullvad is "manual connect" with lockdown on, so this is fail-closed while lockdown holds, but if lockdown is ever toggled off the fallback path sends DNS in the clear to third parties. **Verified.** Next: `services.resolved.settings.Resolve.FallbackDNS = []` (note the obsolete `fallbackDns` alias warning from eval).

6. **`.claude/main/recovery.md:28-43`** — The re-enroll command binds PCR 0+7, so every firmware update (fwupd is enabled) breaks TPM unlock, not only "PCR 7" changes as line 30 says; no PIN; any of the 5 retained signed generations unlocks the disk. The actual enrolled PCR set is unknown to the repo. **Plausible** (LUKS header not readable without root). Next: record the enrolled policy and its rationale in the runbook; consider `+pin` or PCR 11 if the threat model wants it.

7. **`modules/nixos/profiles/security.nix:42-58`** — fail2ban on `main` guards an sshd that is reachable only over `tailscale0`; it adds a persisted ban DB and a 5.8-exposure daemon for no realistic gain, and the assertion at `:53-58` forces it on. Low. Next: per-host exemption or an explicit "defence in depth" note.

Checked and fine: sudo allowlist matches live `sudo -l` exactly and is root-equivalent only via the documented `nixos-switch-main`; `.sops.yaml` main rule and `secrets.yaml` recipients match (user + main host key only); `boot.initrd.secrets` assertion holds; Secure Boot enabled (user mode), TPM2 present, lanzastub 1.1.0.

## 4. Stale workarounds (worth re-testing)

1. **`hosts/main/default.nix:468-481`** — The dbus-broker user-unit override's rationale ("the user-scope launcher does not implement the reload-notification protocol") is wrong: upstream `dbus-broker` v37 `launcher.c` sends `RELOADING=1` + `MONOTONIC_USEC` and then `READY=1` on SIGHUP, unconditionally on scope. The override does work (journal: "Caught SIGHUP, trigger reload" → "Reloaded D-Bus User Message Bus"), so the original hang had another cause. **Rationale refuted against upstream source; workaround effect verified.** Next: re-test a switch without the override on dbus-broker 37 / systemd 261.2 and capture the real failure; update the memory note if it no longer reproduces.

2. **`hosts/main/default.nix:240,485-529`** — The btusb blacklist + `sleep 5` loader and the busctl power-on loop. Journal since 05-16: the original errors did occur (2× "Failed to send firmware data", 6× "device descriptor read/64, error -71"), the power-on unit failed only on 2026-05-27, and bluetoothd's "Failed to set default system config for hci0" still fires (66×, last 2026-08-15), so the AutoEnable race is real and the power-on unit earns its place. The fixed 5 s sleep is the untested part. **Verified.** Next: re-test the blacklist on kernel 6.18.50 / bluez 5.87; if still needed, replace the sleep with a udev-triggered load.

3. **`hosts/main/default.nix:416-428`** — fwupd `CAP_DAC_OVERRIDE/CHOWN/FOWNER` rationale is **still true**: nixpkgs `fwupd.nix:214-229` runs `fwupd-refresh` as `User=fwupd-refresh` with `StateDirectory=fwupd`, and `/var/lib/fwupd` is live-owned by `fwupd-refresh:fwupd-refresh`. fwupd 2.1.6. Keep.

4. **`hosts/main/default.nix:354-370`** — thermald's `perf_event_open` allowance: thermald runs with an empty `CapabilityBoundingSet` and `perf_event_paranoid=2`, so as capability-less root it cannot open perf events anyway; either the syscall entry is unnecessary or RAPL reading is silently degraded (no warnings in the journal). `--adaptive` claim confirmed. **Plausible.** Next: run thermald with debug logging once; add `CAP_PERFMON` or drop the entry and the comment.

5. **`modules/nixos/profiles/observability/collectors.nix:634-668`** — `TimeoutStopSec=10s` bounds but does not fix the stop hang (Drift #3). The real lever is prometheus `--storage.remote.flush-deadline` (default 1 m) and alloy's write timeouts; `opentelemetry-collector` is not covered at all. **Verified.** Next: set the flush deadline, cover otel, and reword the comment.

6. **`hosts/main/backups.nix:116-120`** — The probe comment justifies itself by `network-online.target` being a no-op; the probe is the thing that fails (Correctness #1). Next: fold into that fix.

7. **`hosts/main/default.nix:41-46`** — "nh ≥ 4.3 refuses to run as root": nh 4.3.0's changelog documents a `--bypass-root-check` flag, so the guard exists but a supported bypass also exists; the comment implies there was none. The hand-rolled wrapper is still the safer choice. **Verified (changelog).** Next: comment tweak only.

8. **`hosts/main/networking.nix:129`** — `systemd-networkd-wait-online.enable = mkForce false` targets a unit that does not exist in stage 2 (`systemd-networkd` is `not-found`). No-op. Trivial.

## 5. Persistence/backup

1. **`hosts/main/impermanence.nix:27-44` + `lib/observability-alerts.nix:51-70`** — `/var/lib/node-exporter-textfiles` is ephemeral, so `restic_last_backup_timestamp_seconds` / `restic_last_check_timestamp_seconds` vanish at every boot and reappear only after the next _successful_ run. The alerts are `time() - metric > N` with no `absent()` term, so a missing series never fires. This is exactly how three months of failed integrity checks went unnoticed; live the directory holds only today's `restic_backup.prom` and `system_metadata.prom`. `hosts/main/CLAUDE.md:88-91` documents the ephemerality as intended. **Verified.** Next: persist the directory (cheap, bounded), and add `absent_over_time(...)` companions to both alerts on homeserver-gcp.

2. **`hosts/main/impermanence.nix`** — `/var/lib/systemd/credential.secret` is not persisted, which breaks any `systemd-creds` host-key credential across boots (Correctness #6). **Verified absent live.** Next: persist as a `files` entry.

3. **`hosts/main/impermanence.nix`** — `/var/lib/prometheus2` (24 h TSDB + remote-write WAL, static user) is ephemeral and undocumented; samples buffered during a tailnet outage are lost on reboot. Low. Next: decide, then document.

4. **`hosts/main/impermanence.nix`** — `/var/lib/NetworkManager` is ephemeral: `secret_key` regenerates per boot (stable-privacy IPv6 IIDs change), `timestamps`/`seen-bssids` reset. `ipv6.addr-gen-mode=default` on the active connection (live `nmcli`). Low, arguably privacy-positive. Next: document as intentional or persist.

5. **`hosts/main/impermanence.nix`** — `/var/lib/power-profiles-daemon` is ephemeral, so the profile chosen with the `power-profile` toggler (`home.nix:218-231`) resets each boot. Low. Next: persist if the reset annoys.

6. **`hosts/main/backups.nix:37-69`** — `~/.claude`, `~/.codex`, `~/.config/gh` carry long-lived API/OAuth tokens into B2 (gcloud tokens are excluded; these are not). Encrypted by restic, so acceptable, but token rotation on repo compromise is not in `docs/security.md`. Observation. Next: add a line to the rotation table.

The `main backup paths are persisted` invariant passes and is correct for what it checks; it cannot detect stale paths (Correctness #8) or metric-visibility gaps (#1 above).

## 6. Test/invariant coverage gaps

1. **`modules/nixos/services/systemd-failure-notify.nix`** — No test exercises a real failure. A VM test with a deliberately failing unit asserting a `systemd-failure-notify` journal line would have caught the `/bin/cat` bug. Next: add to `tests/nixos/`.

2. **`hosts/main/backups.nix:114-145`** — No test runs `restic-check-local` end to end. A VM test against a local `rest-server`/file repo (ExecStartPre → check → `.prom` written) would have caught the probe. Next: add, or at least an eval invariant that the probe logs stderr.

3. **`flake/checks.nix` / `lib/invariants.nix`** — No invariant that `hardware.cpu.{intel,amd}.updateMicrocode` is true on physical x86 hosts (`main`, `mac`). Next: add to `commonSystemInvariants` gated on `hardware.enableRedistributableFirmware`.

4. **`tests/nixos/`** — Nothing covers initrd networking + stage-2 NTP. A test with `boot.initrd.network.enable` + NetworkManager asserting no stale `/run/systemd/netif/state` (or `NTPSynchronized=yes` against a test NTP server) would pin Correctness #3. Next: add.

5. **`lib/invariants.nix:198-242`** — The anonymous specialisation has an eval allowlist check but no runtime test; a booted test asserting `mullvad status` / Tor bootstrap behaviour would have exposed Correctness #4. Heavy; alternatively an eval check that `/etc/mullvad-vpn` is persisted _iff_ auto-connect is configured.

6. **`flake/checks.nix` (observability-alerts-lint)** — `promtool check rules` only; no `promtool test rules` cases, so the absent-series blind spot in `ResticBackupStale`/`ResticCheckStale` is untested. Next: add unit tests with an absent series expecting an alert.

7. **`lib/invariants.nix:244+` (`checkMullvadTailscaleCoexistence`)** — Checks unit wiring but not the substance: assert the nftables content contains `ct mark set 0x00000f41` and the bypass script contains `route replace 100.64.0.0/10 dev tailscale0 table main`. Cheap. Next: extend.

8. **`hosts/main/default.nix:219-222`** — No check that a `fprintAuth` setting is effective (Correctness #7). Next: an eval check that the target PAM service's generated text contains `pam_fprintd` when `fprintAuth` is true.

9. **`lib/invariants.nix:511-529` (`mainUsbguardIsDenyDefault`)** — Only asserts an `allow id` and a `reject` exist. Once Security #4 lands, assert internal-device rules carry `with-connect-type "hardwired"`.

10. **`scripts/check-host-drift.sh`** — Could verify that every `restic.backups.local.paths` entry exists on the live host (would catch Correctness #8). Next: extend the drift facts.

## 7. New capability ideas (each tied to a gap above)

1. **Push-pipeline liveness** — Homeserver-gcp cannot alert about a host that stops pushing (Tailscale down since 08-19, unnoticed). Add per-host freshness alerts (`absent_over_time(up{host="main"}[24h])`, `nixos_system_activated_at_seconds` staleness) on homeserver-gcp, and on `main` a timer that fails when `tailscale status --json` `BackendState != Running` for > N h or `prometheus_remote_storage_samples_failed_total` climbs, wired into failure-notify once Correctness #2 is fixed.

2. **Failure-notify coverage** — After the `/bin/cat` fix, set `webhookUrlFile` on `main` and extend `default.nix:338-349` (five units today) to fwupd, tailscaled, mullvad-daemon, mullvad-lockdown, tailscale-bypass-routing, bluetooth-power-on, usbguard, dlm, systemd-timesyncd. Desktop delivery: a user unit on `nixos-fake-graphical-session.target` following `journalctl -t systemd-failure-notify -f`.

3. **Clock health** — Add the `timex` collector to `collectors.nix:511-521` and a `node_timex_sync_status == 0` alert (Correctness #3 would have surfaced in days, not months).

4. **Restore canary on `main`** — `ResticRestoreCanaryStale` exists fleet-wide but `main` never emits `restic_last_restore_test_timestamp_seconds`, so it is blind for this host. Mirror homeserver-gcp's canary (restore one small path weekly, write the `.prom`).

5. **Sandbox the unfree/root daemons** — `services.hardened.dlm`, `restic-backups-local`, `btrbk-local`, `alloy`, `opentelemetry-collector` (Security #3), using the existing DSL and the `profile-hardening` score test pattern.

6. **Re-enable libvirt secret encryption** — Persist `credential.secret`, drop the `mkForce` block (Correctness #6, Persistence #2); Whonix VM secrets then rest encrypted.

7. **USBGuard connect-type pinning** — `with-connect-type "hardwired"` + interface sets for internal devices; `IPCAccessControlFiles` to make `user` list-only (Security #4).

8. **Tailscale journal noise** — While `tailscale down`, `tailscaled` logs a DERP health flap every 10 s (1,591 lines this boot; journal is 939 MB). Either stop the unit when down (`systemctl stop tailscaled` in the operator runbook) or drop `no-derp-connection` lines in Alloy's journal source to save Loki ingest.

9. **Bluetooth race without the sleep** — Replace the fixed `sleep 5` with a udev `ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="8087", ATTR{idProduct}=="0026"` trigger for the loader, keep the power-on unit, add it to failure-notify (Stale #2).

10. **Alert rule unit tests** — `promtool test rules` in `observability-alerts-lint` covering absent-series and threshold cases (Coverage #6).

---

Suggested triage order: Security #1 (microcode), Correctness #1/#2 together (check failing + notifier dead), Correctness #3 (NTP), Persistence #1 + Capability #1 (make silence visible), then Correctness #4/#6 (anonymous Mullvad, libvirt), then the doc sweep.
