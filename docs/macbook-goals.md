# MacBook Air Goals

Repurpose a 2017 MacBook Air 13-inch (A1466) as a **companion workstation**
tightly coupled to `main`. The Mac is not a server. It is a second seat that
shares input, screens, files, and shell sessions with the primary machine.

## Topology

| Node             | Role                                                                              |
| :--------------- | :-------------------------------------------------------------------------------- |
| `main` (laptop)  | Primary interactive: coding, editing, local tests, GUI work, VMs/labs, deploys    |
| `mac`            | Companion / thin client: second workspace, Input Leap, Moonlight, Syncthing, tmux |
| `homeserver-gcp` | Public services + LGTM/backups (unchanged)                                        |

The Mac is **not** a build machine, **not** a CI worker, and **not** a primary
service host. Heavy work happens on `main` (interactive) or `homeserver-gcp`
(headless services).

Deploys follow the existing pattern: build on `main`, ship the diff to the
target via `deploy-rs`. The Mac becomes a third deploy target alongside
`main` and `homeserver-gcp`. Rebuilding directly on the Mac (`nh os switch`)
is supported but slower — `deploy '.#mac'` from `main` is the
default path.

## Hardware

| Component   | Detail                                                                    |
| :---------- | :------------------------------------------------------------------------ |
| CPU         | Intel Core i5-5350U (Broadwell, x86_64)                                   |
| GPU         | Intel HD Graphics 6000 (modesetting, no discrete)                         |
| RAM         | 8 GB LPDDR3 (non-upgradable)                                              |
| WiFi        | Broadcom BCM4360 — needs firmware (see below)                             |
| Storage     | 128 GB Apple SSD — `/dev/disk/by-id/ata-APPLE_SSD_SM0128G_S2XUNY4M230628` |
| Ethernet    | No built-in port — USB-to-ethernet adapter required                       |
| Secure Boot | No T2 chip (pre-2018) — standard EFI boot, no lockout                     |

8 GB RAM + dual-core Broadwell is the hard ceiling. It is enough for a
browser, a terminal, an editor, and a Moonlight stream — not much beyond.

## Workloads

### Input Leap endpoint

Shared keyboard/mouse between `main` and the Mac. `main` runs the server,
the Mac runs the client, connected over Tailscale (so it works regardless of
LAN). Wayland support on the client side has rough edges on Hyprland; expect
to test the cursor-handoff path before relying on it.

### Moonlight client

Stream a desktop or app from `main` (Sunshine host, NVENC via the NVIDIA GPU)
to the Mac. Lets heavy GUI work stay on `main` while the Mac becomes the
display surface for that workload. Good fit because the Mac's own GPU is
weak but H.264/H.265 decode is fine.

### Syncthing node

Always-on (when open) peer for the Mac's home directory and any shared
folders. Runs as a Home Manager user service so pairing state and accepted
folders live with the user, not in a system-level Syncthing service.

### Persistent tmux session

A long-lived tmux on the Mac for session continuity _when working at the Mac_.
**Caveat:** a closed laptop lid suspends the host; tmux sessions die with it
unless lid-close is configured to ignore or `tmux` is launched under a
systemd user service with `systemd-inhibit`. For tmux sessions that must
survive everywhere, prefer `homeserver-gcp` — it is always on.

### Browser, docs, chat

Secondary workspace for reading and communication so `main` stays focused on
the active edit/build loop. No state of consequence lives only on the Mac.

### Emergency SSH workstation

If `main` is broken (mid-rebuild, kernel panic, hardware fault), the Mac is
the fallback that can SSH into `homeserver-gcp` and the home LAN. Worth a few
MB of config to keep alive.

### Light automation

Small recurring jobs that benefit from a LAN-resident host: e.g. mDNS
discovery, local backups of nearby devices, a Tailscale subnet router for
home LAN devices that should not run Tailscale themselves.

## Non-workloads

- **No Forgejo, runner, or self-hosted CI.** GitHub Actions stays as-is.
- **No mirror of `homeserver-gcp` services** (Vaultwarden, Grafana, etc.).
- **No public services** or port exposure off the tailnet.

## Prerequisites

- [ ] Wired install path: USB-to-ethernet adapter (BCM4360 firmware is not in
      the minimal ISO). iPhone USB tethering is a viable fallback.
- [ ] USB drive for the installer ISO.

## Status (2026-05-20)

Configuration is **installed on the MacBook Air** and wired as a companion
workstation. It is reachable over Tailscale as `mac.tail90fc7a.ts.net` /
`100.73.117.103`. The post-install smoke checks pass: SSH works, the system is
running, no units are failed, Tailscale is authed, secrets are decrypted,
impermanence mounts are in place, and `deploy --dry-activate '.#mac'` reaches
the target successfully.

What's already in the repo:

- `lib/hosts.nix` — `mac` registry entry (role=desktop + profiles=[desktop],
  packs=[browsing, coding], enableSpotify=false, no backup class).
- `.sops.yaml` — `&mac_host` recipient + `hosts/mac/secrets/.*` creation rule.
- `hosts/mac/secrets/ssh_host_ed25519_key.enc` + `.pub.enc` — pre-baked
  ed25519 host key encrypted under `&mac_host` and the operator's age key.
- `hosts/mac/secrets/secrets.yaml` — encrypted `user_password` + `root_password`
  (both reuse `main`'s hash so the same login works) + `observability_ingest_password`.
- `hosts/mac/disko.nix`, `hardware-configuration.nix`, `impermanence.nix`,
  `default.nix`, `CLAUDE.md`.
- `home/users/user/mac.nix` — Mac-specific Home Manager additions:
  `input-leap`, `moonlight-qt`, Syncthing, and helper aliases.
- `home/users/user/main.nix` + `hosts/main/default.nix` — `main` has
  `input-leap`, Sunshine, and Tailscale-scoped firewall ports for companion
  access from the Mac.
- `flake/checks.nix` — `invariants-mac` + `mac-sops-bootstrap` checks.
- `scripts/validate.sh` — `host mac` target + light-suite entries.
- `docs/operations.md` — mac in the deploy matrix.

What deliberately diverged from the original plan:

- `homeManager.role = "desktop"` with `profiles = ["desktop"]` and
  `packs = ["browsing" "coding"]`. The plan said `role = "workstation"`,
  which isn't a valid role — `workstation` is a profile, not a role.
  Packs `latex` (texlive scheme-medium) and `learning` (anki) are dropped
  to fit the 128 GB SSD; the `home.nix` developer-tool block (gcc, nodejs,
  claude-code, gh, etc.) stays.
- No `backup.class`. The plan said `"minimal"`, which isn't a valid class.
  Canonical state lives on `main`; mac is impermanent + Syncthing-backed.
- `wheelNeedsPassword = false`. Required for `deploy-rs` activation;
  console access is gated by the LUKS passphrase and SSH password auth is
  off, so the password is only meaningful at the physical console.
- `boot.loader.efi.canTouchEfiVariables = false`. Apple firmware drops
  EFI variable writes silently; systemd-boot's fallback bootloader at
  `/EFI/BOOT/BOOTX64.EFI` is reachable via the Option-key boot picker.
- Hyprland is inherited from the desktop Home Manager/NixOS profiles.
  Mac-specific companion apps are now wired through `home/users/user/mac.nix`.
  Syncthing runs as a Home Manager user service; device pairing and concrete
  folder selection are intentionally live Syncthing state rather than guessed
  device IDs in this repo.
- Home Manager user secrets are disabled on `mac`; that host does not carry
  the operator age key at `~/.config/sops/age/keys.txt`. System secrets still
  decrypt through the Mac SSH host key.

## Install Runbook (archived)

The install has already been completed. Keep this archived runbook only for a
future reinstall.

### Prerequisites

- [ ] Wired install path: USB-to-Ethernet adapter (BCM4360 firmware is
      unavailable in the minimal ISO). iPhone USB tethering is a viable
      fallback.
- [ ] USB stick for the installer ISO (≥ 2 GB).
- [ ] LUKS passphrase chosen (store it in your password manager **before**
      starting; there is no initrd SSH fallback configured for mac, and no
      TPM2 unlock).

### 1. Build and flash the installer ISO

```bash
cd ~/nix
nix build '.#packages.x86_64-linux.installer-iso'
lsblk                                          # confirm target USB device
sudo dd if=result/iso/*.iso of=/dev/sdX bs=4M status=progress oflag=sync
sync
```

The ISO is built from `hosts/installer/default.nix`: minimal NixOS with
SSH on port 22 and authorized keys from `lib/pubkeys.nix`. No special
ISO is needed for mac.

### 2. Boot the Mac from USB

1. Plug in USB-Ethernet **before** powering on.
2. Hold ⌥ Option while powering on the Mac.
3. Select "EFI Boot" from the firmware boot picker.
4. The installer comes up with a console login as `root` (passwordless)
   and `sshd` listening on port 22.

### 3. Find the installer IP

From the Mac console:

```bash
ip -4 -o addr show dev <eth-iface>
```

(or just `ip a` and read off the wired NIC). The installer ISO does **not**
join Tailscale automatically, so use the LAN IP.

### 4. Prepare extra-files with the decrypted SSH host key

On `main`, in the repo root:

```bash
EXTRA=$(mktemp -d)
mkdir -p "$EXTRA/persist/etc/ssh"
nix shell nixpkgs#sops --command sops --decrypt \
  --input-type binary --output-type binary \
  hosts/mac/secrets/ssh_host_ed25519_key.enc \
  > "$EXTRA/persist/etc/ssh/ssh_host_ed25519_key"
nix shell nixpkgs#sops --command sops --decrypt \
  --input-type binary --output-type binary \
  hosts/mac/secrets/ssh_host_ed25519_key.pub.enc \
  > "$EXTRA/persist/etc/ssh/ssh_host_ed25519_key.pub"
chmod 600 "$EXTRA/persist/etc/ssh/ssh_host_ed25519_key"
chmod 644 "$EXTRA/persist/etc/ssh/ssh_host_ed25519_key.pub"
```

The plaintext key is short-lived (next step uses it, last step wipes it).
`nixos-anywhere --extra-files` copies this directory tree to `/` on the
target, so the key lands on the `@persist` btrfs subvolume after disko
mounts it. On every subsequent boot the key is bind-mounted at
`/etc/ssh/ssh_host_ed25519_key` by `impermanence-base.nix`, and sops reads
it directly from `/persist/etc/ssh/...` via `sops.age.sshKeyPaths`.

### 5. Run nixos-anywhere from `main`

```bash
nix develop --command nixos-anywhere \
  --flake '.#mac' \
  --extra-files "$EXTRA" \
  root@<installer-ip>
```

For the temporary reverse-tunnel install path, use the GCP loopback tunnel
instead of the LAN IP:

```bash
nix develop --command nixos-anywhere \
  --flake '.#mac' \
  --extra-files "$EXTRA" \
  --ssh-option StrictHostKeyChecking=no \
  --ssh-option UserKnownHostsFile=/tmp/mac-installer-root-known-hosts \
  --ssh-option 'ProxyCommand=ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/gcp-jump-known-hosts -W %h:%p user@100.103.234.89' \
  --ssh-port 2200 \
  root@127.0.0.1
```

Disko will:

1. Partition the SSD: 512 MB ESP (`mac-boot`) + LUKS (the rest).
2. Prompt for the LUKS passphrase — use the one you stored in step 0.
3. Create Btrfs with `@root`, `@home`, `@nix`, `@persist` subvolumes.
4. Mount everything, copy the closure, install systemd-boot.
5. Reboot.

### 6. Wipe the plaintext key

```bash
shred -uz "$EXTRA/persist/etc/ssh/ssh_host_ed25519_key" \
          "$EXTRA/persist/etc/ssh/ssh_host_ed25519_key.pub"
rm -rf "$EXTRA"
```

### 7. First-boot verification (SSH from `main` over LAN or Tailscale)

The Mac should:

- Prompt for LUKS at the bootloader.
- Reach stage 2 cleanly (no `rollback-root.service` failure).
- Have sops-decrypted secrets at `/run/secrets/{user,root}_password`.
- Set both user and root passwords (same hash as main).
- Bring up Tailscale on first boot (run `sudo tailscale up` interactively
  if no auth key is present in sops; we did not pre-bake one).

```bash
ssh user@mac.tail90fc7a.ts.net
sudo test -s /run/secrets-for-users.d/1/user_password
sudo test -s /run/secrets-for-users.d/1/root_password
sudo systemctl is-active sshd tailscaled alloy prometheus-node-exporter prometheus
systemctl --failed --no-pager
findmnt -R / -o TARGET,SOURCE,FSTYPE,OPTIONS
```

### 8. Disk pointer

`hosts/mac/disko.nix` uses the stable device id reported by the installed
system:

```bash
/dev/disk/by-id/ata-APPLE_SSD_SM0128G_S2XUNY4M230628
```

### 9. Add Tailscale auth key to sops (optional, only if you want the Mac

to come up authed without an interactive `tailscale up`)

Follow the homeserver-gcp pattern: add `tailscale_auth_key` to
`hosts/mac/secrets/secrets.yaml`, wire it via `services.tailscale.authKeyFile`,
redeploy.

## Acceptance Criteria

Pre-install (done):

- [x] Host evaluates cleanly in `nix flake check`.
- [x] `invariants-mac` and `mac-sops-bootstrap` checks pass.
- [x] `bash scripts/validate.sh host mac` builds the closure end-to-end
      (including the out-of-tree `broadcom_sta` module).

Post-install (next session):

- [x] Mac reaches stage 2, no failed units.
- [x] SSH from `main` over Tailscale works.
- [x] `deploy --dry-activate '.#mac'` from `main` reaches activation.
- [x] Host appears in Grafana node dashboard via observability-client.
- [x] User and root console login both work (hash from sops verified remotely;
      physical TTY login still requires a keyboard/screen check).
- [x] Disk pointer in `disko.nix` replaced with `/dev/disk/by-id/...`.

Workload follow-ups (not part of the bootstrap):

- [x] `home/users/user/mac.nix` adds `input-leap`, `moonlight-qt`, and
      `services.syncthing.enable = true`.
- [x] `main` has Input Leap and Sunshine packages/services with the relevant
      Tailscale interface ports opened.
- [ ] Pair Syncthing devices in the GUI and accept only the folders that
      should exist on the 128 GB Mac SSD.
- [ ] Complete Input Leap TLS certificate exchange, then use `input-main` on
      the Mac and `input-server` on `main`.
- [ ] Pair Moonlight against Sunshine on `main`; use `moon-main` on the Mac.

## Open Questions

1. **Subnet router:** does the home LAN have devices that benefit from a
   Tailscale-resident peer? If not, skip `useRoutingFeatures = "server"`.
2. **Wi-Fi vs Ethernet at rest:** `broadcom_sta` is CVE-flagged. If the Mac
   sits docked most of the time, consider running with `wl` blacklisted and
   USB-Ethernet always present.
