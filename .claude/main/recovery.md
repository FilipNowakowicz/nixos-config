## Recovery Notes

### Boot layer map

```
firmware UEFI → Lanzaboote (Secure Boot, sbctl keys in /var/lib/sbctl)
             → initrd: TPM2 unlocks cryptroot, or initrd SSH fallback on port 2222
             → rollback-root.service: @root-blank → @root btrfs snapshot
             → stage 2: sops decrypts secrets using SSH host key from /persist
             → services start
```

### Out-of-band secrets (must be in an external password manager)

These cannot be recovered from B2 without each other — store them offline before you need them:

| Secret                                      | Why it's the break-glass                                                                                       |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| **Age key** (`~/.config/sops/age/keys.txt`) | Decrypts all sops secrets from the git repo, giving restic password + B2 credentials without touching the disk |
| **LUKS passphrase**                         | Unlocks disk when TPM fails and no wired ethernet is available for initrd SSH                                  |
| **Restic repository password**              | Alternative first step: opens the B2 backup directly to retrieve SSH host key                                  |
| **B2 application key ID + key**             | Required alongside restic password to authenticate to Backblaze                                                |

The circular dependency: restic password is in a sops secret → sops needs the SSH host key → SSH host key is in B2 → B2 needs restic password. The age key breaks this cycle: it can decrypt the sops file directly from the git repo without touching B2.

### TPM2 unlock

TPM2 auto-unlock is configured via `crypttabExtraOpts = [ "tpm2-device=auto" ]`; the actual PCR policy was set at enroll time.

**Fails after**: Lanzaboote key rotation, sbctl key re-enrollment, firmware update that changes PCR 7, Secure Boot re-enrollment.

Diagnose which slots are enrolled:

```bash
systemd-cryptenroll /dev/disk/by-id/nvme-eui.0025388401c2aa47-part2
```

Re-enroll TPM after a Secure Boot change (requires LUKS passphrase):

```bash
systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-id/nvme-eui.0025388401c2aa47-part2
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/disk/by-id/nvme-eui.0025388401c2aa47-part2
```

### Initrd SSH (fallback unlock)

- Port **2222**, wired Ethernet only — **a USB-C ethernet dongle is required**.
- Authorized key: `lib/recovery-pubkeys.nix` (one key, `recovery@main`). The private key must be on a second device (phone, secondary laptop). Document where.
- Connect and unlock:
  ```bash
  ssh -p 2222 root@<dhcp-ip>
  # The prompt is a passphrase dialog for cryptroot.
  ```
- The network is torn down immediately before stage 2 starts (`flush-network-before-stage2.service`).
- The initrd SSH host key is a sops secret bundled into the initrd at `nh os switch` time. If the secret is rotated, switch again to update the initrd image.

### Secure Boot / Lanzaboote PKI

sbctl keys are persisted at `/var/lib/sbctl` and backed up to B2.

**Firmware reset / CMOS clear / motherboard replacement**: keys are gone from firmware but files survive.

1. Boot a live ISO (disable Secure Boot temporarily in UEFI setup).
2. Restore `/var/lib/sbctl` from B2 (see disaster restore below).
3. Re-enroll keys into firmware: `sbctl enroll-keys --microsoft`
4. Re-enroll the TPM slot — PCR 7 changed with the new Secure Boot state (see TPM section above).

**sbctl PKI lost entirely** (no B2): `sbctl create-keys && sbctl enroll-keys --microsoft && sbctl sign -s`.

### @root-blank integrity

`rollback-root.service` snapshots `@root-blank` → `@root` before `sysroot.mount`. If `@root-blank` is missing, the service fails and the initrd does not reach stage 2.

Verify on a running system:

```bash
sudo btrfs subvolume list / | grep root-blank
```

Recreate from a live ISO:

```bash
cryptsetup luksOpen /dev/disk/by-id/nvme-eui.0025388401c2aa47-part2 cryptroot
mount -t btrfs -o subvol=/ /dev/mapper/cryptroot /mnt
# If @root is clean enough:
btrfs subvolume snapshot -r /mnt/@root /mnt/@root-blank
# Or start from empty:
btrfs subvolume create /mnt/@root-blank
```

### Sops / age key

- Sops uses the SSH host key at `/persist/etc/ssh/ssh_host_ed25519_key` (converted to age) as the primary decryption key.
- A second age key at `~/.config/sops/age/keys.txt` is also authorized (see `.sops.yaml`).
- The age key is backed up to B2 via `~/.config/sops` — but retrieving it from B2 requires the restic password. Store the age key content in a password manager so it's available before B2 is accessible.
- With the age key alone, you can decrypt any sops secrets file from the git repo — no disk access needed.

### Disaster recovery (new machine / disk loss)

Prerequisites (from your external password manager):

- Age key, OR restic password + B2 application key

**Restore via B2**:

```bash
# Recover the repo URL from sops if you still have the age key + repo checkout:
export RESTIC_REPOSITORY="$(sops --decrypt --extract '["restic_repository"]' \
  hosts/main/secrets/secrets.yaml)"
# Otherwise paste the literal `b2:<bucket>:/main` from your password manager.
export RESTIC_PASSWORD="<from password manager>"
export B2_ACCOUNT_ID="<key id>"
export B2_ACCOUNT_KEY="<key>"
# Browse available snapshots
restic snapshots
# Restore SSH host key so sops works on first boot
restic restore latest --include /etc/ssh --target /mnt/persist
# Restore home and other critical paths
restic restore latest --target /
```

**Fresh install flow**:

1. Boot the installer ISO.
2. `nixos-anywhere --flake .#main <target>` — partitions with disko and installs.
3. Before first boot, inject the SSH host key into `/persist` so sops can decrypt on activation:
   ```bash
   mount -t btrfs -o subvol=/@persist /dev/mapper/cryptroot /mnt/persist
   mkdir -p /mnt/persist/etc/ssh
   # Restore from B2 as above, or copy from backup media
   ```
4. First boot: sops decrypts using the restored SSH host key; services start normally.
5. Verify: `sudo systemctl start restic-check-local.service`

### LUKS passphrase

The LUKS passphrase is not managed by Nix — it was set at install time. Verify a slot is enrolled:

```bash
sudo cryptsetup luksDump /dev/disk/by-id/nvme-eui.0025388401c2aa47-part2 | grep -E 'Keyslot|State'
```

If only the TPM slot is enrolled and TPM fails without initrd SSH available, there is no recovery path. **Keep the passphrase in your external password manager.**
