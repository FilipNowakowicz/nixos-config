# MacBook Air Goals

A 2017 MacBook Air 13-inch (A1466) repurposed as a **companion workstation**
tightly coupled to `main`. The Mac is not a server. It is a second seat that
shares input, screens, files, and shell sessions with the primary machine.

The host is **active**. Install runbook, gotchas, and recovery notes live in
[`hosts/mac/CLAUDE.md`](../hosts/mac/CLAUDE.md); this document keeps the
topology, intended workloads, and open follow-ups.

## Topology

| Node             | Role                                                                               |
| :--------------- | :--------------------------------------------------------------------------------- |
| `main` (laptop)  | Primary interactive: coding, editing, local tests, GUI work, VMs/labs, deploys.    |
| `mac`            | Companion / thin client: second workspace, Input Leap, Moonlight, Syncthing, tmux. |
| `homeserver-gcp` | Public services + LGTM/backups (unchanged).                                        |

The Mac is **not** a build machine, **not** a CI worker, and **not** a primary
service host. Heavy work happens on `main` (interactive) or `homeserver-gcp`
(headless services).

Deploys follow the existing pattern: build on `main`, ship the diff via
`deploy-rs`. `deploy '.#mac'` from `main` is the default path; rebuilding
directly on the Mac (`nh os switch`) is supported but slower.

## Hardware

| Component   | Detail                                                |
| :---------- | :---------------------------------------------------- |
| CPU         | Intel Core i5-5350U (Broadwell, x86_64)               |
| GPU         | Intel HD Graphics 6000 (modesetting, no discrete)     |
| RAM         | 8 GB LPDDR3 (non-upgradable)                          |
| WiFi        | Broadcom BCM4360 — needs the `broadcom_sta` module    |
| Storage     | 128 GB Apple SSD (by-id in `lib/hosts.nix`)           |
| Ethernet    | No built-in port — USB-to-Ethernet adapter required   |
| Secure Boot | No T2 chip (pre-2018) — standard EFI boot, no lockout |

8 GB RAM + dual-core Broadwell is the hard ceiling. It is enough for a
browser, a terminal, an editor, and a Moonlight stream — not much beyond.

## Workloads

### Input Leap endpoint

Shared keyboard/mouse between `main` and the Mac. `main` runs the server, the
Mac runs the client, connected over Tailscale (so it works regardless of LAN).
Wayland support on the client side has rough edges on Hyprland; expect to test
the cursor-handoff path before relying on it.

### Moonlight client

Stream a desktop or app from `main` (Sunshine host, NVENC via the NVIDIA GPU)
to the Mac. Lets heavy GUI work stay on `main` while the Mac becomes the
display surface. Good fit because the Mac's own GPU is weak but H.264/H.265
decode is fine.

### Syncthing node

Always-on peer for the Mac's home directory and shared folders. Runs as a Home
Manager user service so pairing state and accepted folders live with the user,
not in a system-level Syncthing service.

### Persistent tmux session

A long-lived tmux on the Mac for session continuity _when working at the Mac_.
**Caveat:** a closed laptop lid suspends the host on battery; tmux sessions die
with it. For tmux sessions that must survive everywhere, prefer
`homeserver-gcp` — it is always on.

### Browser, docs, chat

Secondary workspace for reading and communication so `main` stays focused on
the active edit/build loop. No state of consequence lives only on the Mac.

### Emergency SSH workstation

If `main` is broken (mid-rebuild, kernel panic, hardware fault), the Mac is the
fallback that can SSH into `homeserver-gcp` and the home LAN.

### Light automation

Small recurring jobs that benefit from a LAN-resident host: mDNS discovery,
local backups of nearby devices, a Tailscale subnet router for home LAN devices
that should not run Tailscale themselves.

## Non-workloads

- **No Forgejo, runner, or self-hosted CI.** GitHub Actions stays as-is.
- **No mirror of `homeserver-gcp` services** (Vaultwarden, Grafana, etc.).
- **No public services** or port exposure off the tailnet.

## Deliberate Divergences From The Original Plan

- `homeManager.role = "desktop"` with `profiles = ["desktop"]` and `packs =
["browsing" "coding"]`. The original plan said `role = "workstation"`, which
  is not a valid role — `workstation` is a profile, not a role. Packs `latex`
  and `learning` are dropped to fit the 128 GB SSD; the `home.nix`
  developer-tool block (gcc, nodejs, claude-code, gh, etc.) stays.
- No `backup.class`. Canonical state lives on `main`; the Mac is impermanent
  and Syncthing-backed.
- `wheelNeedsPassword = false`. Required for `deploy-rs` activation; console
  access is gated by the LUKS passphrase and SSH password auth is off, so the
  password is only meaningful at the physical console.
- `boot.loader.efi.canTouchEfiVariables = false`. Apple firmware drops EFI
  variable writes silently; systemd-boot's fallback bootloader at
  `/EFI/BOOT/BOOTX64.EFI` is reachable via the Option-key boot picker.
- Home Manager user secrets are disabled; the Mac does not carry the operator
  age key at `~/.config/sops/age/keys.txt`. System secrets still decrypt
  through the persisted SSH host key. Git identity is configured manually.

## Open Follow-Ups

- [ ] Pair Syncthing devices in the GUI and accept only the folders that should
      exist on the 128 GB Mac SSD.
- [ ] Complete Input Leap TLS certificate exchange, then use `input-main` on
      the Mac and `input-server` on `main`.
- [ ] Pair Moonlight against Sunshine on `main`; use `moon-main` on the Mac.

## Open Questions

1. **Subnet router:** does the home LAN have devices that benefit from a
   Tailscale-resident peer? If not, skip `useRoutingFeatures = "server"`.
2. **Wi-Fi vs Ethernet at rest:** `broadcom_sta` is CVE-flagged. If the Mac
   sits docked most of the time, consider running with `wl` blacklisted and
   USB-Ethernet always present.
