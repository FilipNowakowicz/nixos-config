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

8. **Verify the disk pointer** in `hosts/mac/disko.nix` still matches the live
   system (`ls -l /dev/disk/by-id | grep APPLE_SSD`), then redeploy if it ever
   changes.
