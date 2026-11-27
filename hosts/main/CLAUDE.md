# main Host

Primary workstation. Uses LUKS, Btrfs, impermanence, Lanzaboote Secure Boot,
Tailscale, Mullvad, USBGuard, Restic/B2 backups, and a full desktop stack.

Status: **active** — hardware-bound to the owner's laptop/workstation.

## Quick Reference

```bash
nh os switch --hostname main .
systemctl status rollback-root.service --no-pager
systemctl list-timers --all --no-pager | rg 'restic|btrfs|fstrim|nix'
journalctl -b -u rollback-root.service --no-pager
sudo systemctl status btrbk-local.timer --no-pager
```

## Storage Model

- **Disk layout**: `hosts/main/disko.nix` targets the stable NVMe by-id path and creates an ESP plus LUKS-encrypted Btrfs.
- **Subvolumes**: `@root`, `@root-blank`, `@home`, `@nix`, and `@persist`.
- **Compression**: all primary subvolumes mount with `compress=zstd`.
- **Ephemeral root**: initrd systemd moves the current `@root` to top-level `old_roots/<timestamp>` and snapshots `@root-blank` back to `@root` on every boot.
- **Local snapshots**: `btrbk-local.timer` snapshots `@home` and `@persist` daily via the hidden `/.btrfs-root` mount, keeping at least 2 days and pruning after 14 days.
- **Persistent mounts**: `hosts/main/impermanence.nix` and `modules/nixos/profiles/impermanence-base.nix` bind state from `/persist`.
- **Boot-critical mounts**: `/nix` and `/persist` are `neededForBoot`; do not remove this without proving stage 1 still reaches stage 2.

## Persistent State

Every stateful path on `main` falls into one of three categories. Adding a new
stateful service means picking one of them deliberately.

### Persisted (bind-mounted from `/persist`)

Identity and crypto:

- `/etc/machine-id`
- `/etc/ssh/ssh_host_ed25519_key*`
- `/var/lib/sbctl` — Lanzaboote / Secure Boot PKI

Network and VPN identity:

- `/etc/NetworkManager/system-connections` — saved Wi-Fi / VPN profiles
- `/etc/mullvad-vpn`, `/var/cache/mullvad-vpn`
- `/var/lib/tailscale`
- `/var/lib/fail2ban` — banned-IP database

Hardware and desktop state:

- `/var/lib/bluetooth` — pairings
- `/var/lib/fprint` — fingerprint enrollments
- `/var/lib/tudor` — fingerprint sensor pairing data
- `/var/lib/usbguard` — rule hashes
- `/var/lib/systemd/backlight` — screen brightness across reboots
- `/var/lib/systemd/rfkill` — radio block state across reboots
- `/var/cache/tuigreet` — `--remember` last-user cache

Operational state:

- `/var/log` — journald and friends
- `/var/lib/nixos` — UID/GID stability across rebuilds
- Crash dumps are stored in the journal by `profiles/security.nix`, not
  persisted as flat files under `/var/lib/systemd/coredump`.
- `/var/lib/systemd/pstore` — kernel panic dumps `systemd-pstore` moves out of
  EFI pstore on the next boot; without it they vanish with the root rollback
- `/var/lib/systemd/timers` — `Persistent=true` timer catchup (e.g. `restic-check-local`)
- `/var/lib/systemd/credential.secret` — systemd-creds host key; libvirt's
  secrets key is encrypted with it. `credential-host-secret.service` creates it in
  `/persist` before impermanence mounts it.
- `/var/cache/restic-backups-local` — restic index/pack cache; loss means re-fetching from B2
- `/var/lib/node-exporter-durable` — `restic_backup.prom` and `restic_check.prom`
  last-success stamps. If a reboot erased them, the `*Stale` alerts would have
  no series to age, and `BackupEvidenceMissing` would fire until the next run.

### Declarative-regenerated (rebuilt by NixOS activation each boot)

Not persisted, but identical after every rebuild because Nix rewrites them
deterministically. Treat as code, not state:

- `/etc/*` not in the persisted list — pulled from `/run/current-system/etc`.
- `/var/lib/private/*` for `DynamicUser=yes` services (alloy) —
  the service unit recreates the runtime tree; only the WAL inside is lost.
- `/var/lib/NetworkManager/` runtime — _saved_ profiles are persisted via
  `/etc/NetworkManager/system-connections`; runtime DHCP leases are not.

### Intentionally ephemeral (reset on every boot, by design)

- `/root`, `/tmp`, `/var/tmp` — start clean.
- `/var/lib/fwupd`, `/var/cache/fwupd*` — refetched by `fwupd-refresh.timer`.
- `/var/lib/systemd/random-seed` — kernel reseeds from hardware entropy.
- `/var/lib/systemd/timesync` — NTP resyncs on boot.
- `/var/lib/upower`, `/var/lib/colord`, `/var/lib/AccountsService` — UX caches
  with no operator-visible loss.
- `/var/lib/node-exporter-textfiles` — per-boot metrics such as
  `system_metadata.prom`, rewritten at every activation. The backup and check
  success stamps live in `/var/lib/node-exporter-durable` instead (persisted).

### Adding a new stateful service

1. Decide which category fits. If it's persisted:
   ```bash
   sudo cp -a /var/lib/<thing> /persist/var/lib/   # snapshot live state first
   ```
   Skip the copy and the bind mount lands on an empty dir; the service loses
   its state at the next rollback boot.
2. Add the path to `environment.persistence."/persist".directories` (or
   `.files`) in `hosts/main/impermanence.nix`.
3. If the path also needs to survive disk loss, add it to
   `services.restic.backups.local.paths` in `hosts/main/backups.nix`. The
   `main backup paths are persisted or on a persistent fs` invariant in
   `flake/checks.nix` enforces backup ⊆ persistence — a backed-up path that
   isn't persisted would silently lose state on rollback and back up the empty
   directory on the next run.
4. `nh os switch --hostname main .` to land the bind mount.

## Backups

`services.restic.backups.local` backs up selected home directories and
persistent service identity to the B2 repository in the `restic_repository`
sops secret on this host.

Important covered state:

- `~/.ssh`, `~/.gnupg`, browser/app profiles, Anki, KWallet, repo checkout.
- `~/.codex`, `~/.claude`, `~/.claude.json`.
- Wi-Fi profiles, Mullvad account/device state, Tailscale node identity,
  Bluetooth pairings, fingerprint enrollments, USBGuard state, Secure Boot PKI,
  machine-id, and SSH host identity.
- Project work that exists only here: `~/trading/secrets`, the research
  outputs in `~/trading/data/{s004,s004-effort,astra}`, and anki-generator's
  `local/` workspace and config. Its live `state.sqlite3` is never read. The
  prepare step writes a verified SQLite copy to `local/restic-snapshot/`, and
  that copy is what gets backed up. To restore, place it as
  `local/workspace/state.sqlite3`.
- Not covered by design: tracked code (on GitHub), linked worktrees,
  downloaded data (Betfair archives, course PDFs, lecture videos), and VM
  images (re-downloadable; they persist locally only).

`checks.main-backup-coverage` backs up a marker tree with the effective
paths and excludes, restores it, and fails if a covered marker is missing or
an excluded one comes back.

Manual verification:

```bash
sudo systemctl start btrbk-local.service
sudo systemctl status btrbk-local.timer --no-pager
sudo btrfs subvolume list /.btrfs-root | rg '\.snapshots'
sudo systemctl start restic-backups-local.service
sudo systemctl start restic-check-local.service
journalctl -u restic-backups-local.service -n 120 --no-pager
journalctl -u restic-check-local.service -n 120 --no-pager
```

The `main` host has scoped passwordless sudo for these snapshot and Restic
start/status commands so an interactive agent can run them after the rule is
deployed.

## Scoped Agent Maintenance Sudo

Normal `wheel` sudo still requires a password. A narrow `NOPASSWD` allowlist
(`agentMaintenanceCommands`, reviewed in `lib/invariants.nix`) covers the
btrbk/Restic, `bootctl`, `efibootmgr -b XXXX -B`, `nix-gc-14d` and
`nixos-switch-main [--remote]` commands above. Policy and the reasons:
[`docs/security.md`](../../docs/security.md#scoped-agent-maintenance-sudo).

## USBGuard: Adding a New USB Device

Runbook: [`.claude/main/usbguard.md`](../../.claude/main/usbguard.md)

## DisplayLink External Monitor (USB dock)

Runbook: [`.claude/main/displaylink.md`](../../.claude/main/displaylink.md)

`modules/nixos/hardware/displaylink.nix` adds the driver when
`hardware.displaylinkDock.enable = true` (off by default; also gated
`!profiles.ci` so the unfree blob stays out of `merge-gate`). Three manual prerequisites before
a dock works: prefetch the `requireFile` driver blob, add a USBGuard allow rule
for the dock, and connect it before logging into Hyprland.

General rule (this is the second instance after fprintd): any unfree/unfetchable
`requireFile` driver added to a CI-built host must be gated behind
`!config.profiles.ci`. The `merge-gate` `main-ci` build is the executable
backstop — an ungated blob makes that closure unfetchable and fails CI — so this
note is just to apply the gate up front rather than discover it via a red gate.

## Recovery Notes

Runbook: [`.claude/main/recovery.md`](../../.claude/main/recovery.md)

## Whonix KVM

Runbook: [`.claude/main/whonix.md`](../../.claude/main/whonix.md)

## Mullvad and Tailscale Coexistence

Three mechanisms keep both VPNs running simultaneously:

1. **nftables mark** (`tailscale-mullvad-compat` table, priority filter−1): sets
   both the conntrack mark (`ct mark 0x00000f41`, Mullvad's split-tunnel mark)
   and the packet mark (`meta mark 0x6d6f6c65`) on outgoing `tailscale0` packets
   before Mullvad's output chain runs (priority filter = 0). Mullvad's output
   chain accepts traffic with `ct mark 0x00000f41` and the return traffic is also
   accepted via the same conntrack mark propagated by Mullvad's prerouting chain.
   Setting only the packet mark is insufficient — Mullvad's output chain only
   checks the conntrack mark, not the packet mark. A `prerouting` chain in the
   same table marks connections peers open _to_ main (KDE Connect from the
   phone, SSH) on `tailscale0`, which Mullvad's input chain otherwise drops;
   `nixos-fw` still limits them to the `tailscale0` ports.
2. **Main-table route injection** (`tailscale-bypass-routing.service`): adds
   `100.64.0.0/10 dev tailscale0` and `fd7a:115c:a1e0::/48 dev tailscale0` to
   the main IPv4/IPv6 routing tables. Mullvad's own `lookup main
suppress_prefixlength 0` rule (at whatever pref Mullvad chooses) finds these
   routes and sends tailnet traffic to tailscale0 before Mullvad's catch-all
   fires. This is immune to Mullvad's pref number changes (observed: 112/113 →
   109/110 → 48/49 across restarts); a destination-based policy rule at a fixed
   pref can never reliably beat a moving target.
3. **Loose reverse-path filtering**: `firewall.checkReversePath = "loose"` to
   accept legitimate asymmetric tunneled return traffic.

Both `tailscaled.postStart` and `mullvad-daemon.postStart` also run the bypass
script so routing is re-asserted whenever either daemon restarts.

## Gotchas

- **disko changes are destructive** unless you are only changing metadata for a future reinstall.
- **Do not persist broad directories by default**; keep persistence minimal and service-owned.
- **OpenSSH uses only the persisted Ed25519 host key**; do not reintroduce volatile RSA host key generation.
- **Mullvad and Tailscale coexistence is fragile**; the three bypass mechanisms in `default.nix` are load-bearing — do not remove the nftables table, the bypass service, or the loose reverse-path setting without understanding all three.
- **Old roots are not normal backups**; they are local forensic rollback artifacts retained for 30 days.
- **Whonix VMs require Gateway before Workstation**; starting Workstation without a running Gateway leaves it without a Tor route.
- **Under the Lua config (Hyprland 0.57+), `hyprctl keyword` is gone and
  `hyprctl dispatch` takes an `hl.dsp` expression**, e.g.
  `hyprctl dispatch "hl.dsp.dpms({ action = 'on' })"`; change options with
  `hyprctl eval 'hl.config({ ... })'` and confirm with `hyprctl getoption`.
  `.agents/learning/promotions/no-legacy-hyprctl-dispatch.sh` rejects the
  legacy forms. Never probe a togglable `hl.dsp` dispatcher live with guessed
  arguments: an unknown action means toggle and `hyprctl` still prints `ok`,
  so a dpms probe can blank the screen. Read Hyprland's
  `LuaBindingsDispatchers.cpp` instead.
- **`exec-once` helpers are not restarted on rebuild, or after a crash.**
  Hyprland `exec-once` fires only at session login, so `nh os switch` /
  `home-manager switch` leaves any changed helper running its pre-rebuild
  binary — and if the process dies for any other reason, nothing brings it
  back either, since `exec-once` has no `Restart=`. The old bar hit the
  crash case: its journal showed it periodically dying with
  "Error reading events from display: Broken pipe", correlating with
  `nixos-switch`/`switch-to-configuration` runs elsewhere on the system (a
  session-adjacent service restart, e.g. ACPI/DisplayLink, apparently severs
  the Wayland connection) — not, as first suspected, with charger/AC events.
  Long-running per-session processes — any GUI/Wayland client, not just
  background helper scripts (`quiet-shell` is the example) — belong in
  `systemd.user.services` bound to
  `graphical-session.target` with `Restart=always` so both a
  rebuild and a crash self-heal. Reserve `exec-once` for true one-shot startup
  commands. When restarting such a helper by hand: `pkill -f
<name>` self-matches the shell running the command (its argv contains
  the token) — kill by PID instead.

### Capturing a boot or resume DNS failure

Run `network-doctor main` at the first opportunity after a normal cold boot or
after resuming on a different network. Capture the first observation before
reconnecting either VPN. Keep the output local because it contains network
addresses and device names. For example, in a shell on main:

```sh
(
  umask 077
  dir="${XDG_STATE_HOME:-$HOME/.local/state}/network-doctor"
  mkdir -p "$dir"
  network-doctor main >"$dir/main-$(date -u +%Y%m%dT%H%M%SZ).log" 2>&1
)
```

Compare boot ID, uptime and physical link with the baseline. If a lookup
fails, inspect the route to AdGuard first. If it selects tailscale0, compare
the UDP and TCP answers. A direct answer with a failed system lookup points
toward resolver selection or the local proxy. If both direct queries time out,
the route lookup alone cannot distinguish a peer, ACL, firewall or listener
failure. On main, MagicDNS names should resolve through Tailscale. Either
Mullvad or the tailnet DNS path is acceptable for public names. Investigate
a public answer attributed to the physical Wi-Fi link. Evaluate direct
AdGuard probes independently, even when the public lookup succeeds.
