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

- **Disk layout**: `hosts/mac/disko.nix` targets `/dev/nvme0n1` (single Apple
  NVMe; replace with `/dev/disk/by-id/nvme-...` after first boot once the id
  is known). 512 MB ESP + LUKS-encrypted Btrfs.
- **Subvolumes**: `@root`, `@home`, `@nix`, `@persist`.
- **Compression**: `compress=zstd` on all primary subvolumes.
- **Ephemeral root**: same rollback pattern as `main`. `@root` is moved to
  `/old_roots/<timestamp>` and reset to `@root-blank` on every boot.
- **No TPM2**: pre-2018 MacBook Air has no T2; LUKS unlock is passphrase-only
  at the bootloader prompt. Keep the passphrase in your password manager —
  there is no initrd SSH fallback configured.

## Persistent State

The persistence list is intentionally coarse: blanket `/var/lib`,
`/var/cache`, and `/root`, plus the explicit network/systemd state entries.
Tighten over time as specific paths prove worth calling out — `main`
started the same way before its persistence list was enumerated.

See `hosts/mac/impermanence.nix` and `modules/nixos/profiles/impermanence-base.nix`
for the actual list.

## Hardware Notes

- **BCM4360 Wi-Fi**: needs the proprietary `broadcom_sta` (`wl`) kernel
  module. The package is CVE-flagged (CVE-2019-9501/9502) and we whitelist
  it explicitly in `default.nix`. Wired USB-Ethernet bypasses the driver
  entirely if you want a safer link.
- **Bootloader**: plain systemd-boot installed with EFI variable writes
  disabled (`boot.loader.efi.canTouchEfiVariables = false`). Apple firmware
  often drops EFI variable changes silently; systemd-boot still drops a
  fallback `/EFI/BOOT/BOOTX64.EFI` that the Option-key boot picker finds.
- **Lid switch**: suspends on battery, ignored on AC power so Syncthing /
  Input Leap stay reachable when docked. Same idle-suspend after 15 min.
- **Heat**: thermald + power-profiles-daemon enabled. Broadwell + 8 GB RAM
  is the hard ceiling; don't expect to run heavy builds locally.

## Sops Bootstrap

Pre-baked host SSH key is committed encrypted to the repo.

- Private key: `hosts/mac/secrets/ssh_host_ed25519_key.enc`
- Public key: `hosts/mac/secrets/ssh_host_ed25519_key.pub.enc`
- Age identity: `&mac_host` in `.sops.yaml` (`age18sl0mheda2g4atmwsn60sds0026p62cd5xr2he2pad3lmrkr24qsvs0sx2`)

`nix build '.#checks.x86_64-linux.mac-sops-bootstrap'` verifies both files
are present.

The pre-baked key is injected during install via
`nixos-anywhere --extra-files` (see "First Install" below). On every boot
after that, `modules/nixos/profiles/impermanence-base.nix` bind-mounts
`/etc/ssh/ssh_host_ed25519_key` from `/persist`, and sops reads it directly
from `/persist/etc/ssh/ssh_host_ed25519_key` via `sops.age.sshKeyPaths`.

## First Install

### Prerequisites

- Wired install path: USB-to-Ethernet adapter (BCM4360 firmware is not in
  the minimal ISO). iPhone USB tethering is a viable fallback.
- USB stick for the installer ISO.

### Steps

1. **Build the installer ISO** on `main`:

   ```bash
   nix build '.#packages.x86_64-linux.installer-iso'
   sudo dd if=result/iso/*.iso of=/dev/sdX bs=4M status=progress oflag=sync
   sync
   ```

   Replace `/dev/sdX` with the USB device (check `lsblk` first).

2. **Boot the Mac from the USB**:

   Hold ⌥ Option while powering on; pick "EFI Boot" from the picker. The
   installer comes up with SSH listening on port 22 (`root` user, authorized
   keys from `lib/pubkeys.nix`). Plug in USB-Ethernet _before_ booting.

3. **Find the Mac's installer IP** (from the Mac console or via `tailscale
status` if the installer ISO joins the tailnet — it does not by default,
   so use the console).

4. **Prepare extra-files with the decrypted SSH host key**:

   ```bash
   EXTRA=$(mktemp -d)
   mkdir -p "$EXTRA/persist/etc/ssh"
   nix shell nixpkgs#sops --command sops --decrypt --input-type binary --output-type binary \
     hosts/mac/secrets/ssh_host_ed25519_key.enc \
     > "$EXTRA/persist/etc/ssh/ssh_host_ed25519_key"
   nix shell nixpkgs#sops --command sops --decrypt --input-type binary --output-type binary \
     hosts/mac/secrets/ssh_host_ed25519_key.pub.enc \
     > "$EXTRA/persist/etc/ssh/ssh_host_ed25519_key.pub"
   chmod 600 "$EXTRA/persist/etc/ssh/ssh_host_ed25519_key"
   chmod 644 "$EXTRA/persist/etc/ssh/ssh_host_ed25519_key.pub"
   ```

5. **Run nixos-anywhere from `main`**:

   ```bash
   nix develop --command nixos-anywhere \
     --flake '.#mac' \
     --extra-files "$EXTRA" \
     root@<installer-ip>
   ```

   Disko partitions the disk, prompts for the LUKS passphrase, and installs.
   Reboot is automatic.

6. **Wipe the plaintext key on `main`**:

   ```bash
   shred -uz "$EXTRA/persist/etc/ssh/ssh_host_ed25519_key" \
             "$EXTRA/persist/etc/ssh/ssh_host_ed25519_key.pub"
   rm -rf "$EXTRA"
   ```

7. **First-boot verification** (SSH from `main`):

   ```bash
   ssh user@<mac-tailscale-ip>
   sudo systemctl status sops-nix.service --no-pager
   sudo systemctl status rollback-root.service --no-pager
   systemctl --failed --no-pager
   ```

   The user/root password hashes from `hosts/mac/secrets/secrets.yaml` are
   re-used from `main`, so the same user password works for console login.

8. **Replace the disk pointer with `/dev/disk/by-id/...`** in
   `hosts/mac/disko.nix` once the live system reports it (`ls -l
/dev/disk/by-id | grep nvme`), then redeploy.

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
  via Syncthing (when implemented) or a fresh install + reclone of `~/nix`.
