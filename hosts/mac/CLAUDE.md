# mac Host

Companion workstation: 2017 MacBook Air (A1466) repurposed as a thin client
tightly coupled to `main`. Uses LUKS, Btrfs, impermanence, Tailscale, sops,
and a desktop stack with the heaviest workflow packs trimmed for the 128 GB
SSD. Canonical state lives on `main`; mac syncs via Syncthing.

Status: **active** — hardware-bound to the laptop.

## Quick Reference

```bash
# Deploy from main:
deploy '.#mac'

# Local rebuild (slower; build runs on the Mac):
nh os switch --hostname mac .

# Verify post-rebuild:
systemctl status rollback-root.service --no-pager
journalctl -b -u rollback-root.service --no-pager
systemctl --failed --no-pager
findmnt -R / -o TARGET,SOURCE,FSTYPE,OPTIONS
```

## Storage Model

- **Disk layout**: `hosts/mac/disko.nix` targets the stable Apple SSD by-id
  path (`/dev/disk/by-id/ata-APPLE_SSD_SM0128G_S2XUNY4M230628`). 512 MB ESP +
  LUKS-encrypted Btrfs.
- **Subvolumes**: `@root`, `@home`, `@nix`, `@persist`.
- **Compression**: `compress=zstd` on all primary subvolumes.
- **Ephemeral root**: same rollback pattern as `main`. `@root` is moved to
  `/old_roots/<timestamp>` and reset to `@root-blank` on every boot.
- **No TPM2**: pre-2018 MacBook Air has no T2. While the host stays at home,
  a sops-managed keyfile (`luks_keyfile` in `hosts/mac/secrets/luks-keyfile.enc`)
  is baked into the initrd via `boot.initrd.secrets` and unlocks LUKS without
  a prompt; the original passphrase still works as fallback. This trades
  at-rest protection for boot convenience — the keyfile sits on the
  unencrypted ESP, so the disk is only protected if pulled from the machine.
  Before the laptop travels: remove the `boot.initrd` keyfile block from
  `default.nix`, run `cryptsetup luksRemoveKey` for the keyfile slot, and
  fall back to the passphrase (or enrol a FIDO2 token).

## Persistent State

The persistence list follows the same explicit-minimum model as `main`.
Canonical state lives on `main`; mac syncs via Syncthing so recovery usually
means a fresh install followed by re-pairing Syncthing.

From `modules/nixos/profiles/impermanence-base.nix` (shared baseline):

- `/var/log`, `/var/lib/nixos`
- `/etc/machine-id`, SSH host keys

From `hosts/mac/impermanence.nix`:

- `/var/lib/tailscale` — tailnet node identity
- `/var/lib/bluetooth` — Bluetooth pairings
- `/etc/NetworkManager/system-connections` — saved Wi-Fi / VPN profiles
- `/var/lib/systemd/timers` — `Persistent=true` timer catchup
- `/var/lib/systemd/backlight` — screen brightness across reboots
- `/var/lib/systemd/rfkill` — radio block state across reboots

## Hardware Notes

- **BCM4360 Wi-Fi**: needs the proprietary `broadcom_sta` (`wl`) kernel
  module. The package is CVE-flagged (CVE-2019-9501/9502) and we whitelist
  it explicitly in `default.nix`. Wired USB-Ethernet bypasses the driver
  entirely if you want a safer link.
- **Bootloader**: plain systemd-boot installed with EFI variable writes
  disabled (`boot.loader.efi.canTouchEfiVariables = false`). Apple firmware
  often drops EFI variable changes silently; systemd-boot still drops a
  fallback `/EFI/BOOT/BOOTX64.EFI` that the Option-key boot picker finds.
- **Lid switch**: suspends on battery, ignored on AC power so Syncthing and
  paired companion services stay reachable when docked. Same idle-suspend
  after 15 min.
- **Heat**: thermald + power-profiles-daemon enabled. Broadwell + 8 GB RAM
  is the hard ceiling; don't expect to run heavy builds locally.

## First Install & Sops Bootstrap

Runbook: [`.claude/mac/install.md`](../../.claude/mac/install.md)

## Ongoing Deploys

```bash
# From main:
deploy '.#mac'
```

`remoteBuild = true` is set globally for deploy-rs nodes, so the Mac builds
locally rather than pulling a pre-built closure from `main`. Builds are slow
on Broadwell + 8 GB; for heavy changes prefer `nh os switch --hostname mac .`
running on the Mac itself with the dev shell available.

## Gotchas

- **disko changes are destructive** — only edit `disko.nix` metadata if you
  are planning a reinstall.
- **Apple firmware drops EFI variables** — boot order changes won't persist;
  rely on the Option-key boot picker if NVRAM gets reset.
- **broadcom_sta is unmaintained** — Wi-Fi works but has known CVEs. Use
  wired USB-Ethernet whenever convenient and prefer Tailscale for anything
  that touches secrets.
- **Lid suspends on battery** — long-running tmux sessions die when the lid
  closes on battery. For session continuity prefer `homeserver-gcp`.
- **No backups** — canonical state lives on `main`; mac files are recoverable
  via Syncthing pairing or a fresh install + reclone of `~/nix`.
