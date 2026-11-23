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

Use a separate recovery environment. Retrieve the personal age identity from
independent escrow and clone the configuration, or retrieve the repository
locator, repository password and backend credentials independently. Test access
before provisioning the replacement. See [key escrow](../../docs/key-escrow.md)
and the [workstation recovery audit](../../docs/recovery-audit.md).

1. In a private Bash shell with sops and Restic, load the repository,
   password and backend credentials using the [drill prerequisites](../../docs/restore-drill.md#prerequisites),
   substituting `hosts/main/secrets/secrets.yaml` for the homeserver file.
   Use the escrowed identity on this machine. Provide private scratch storage
   large enough for the selected restore.
2. Select a specific workstation recovery point. Restore initially into scratch:

   ```bash
   restic snapshots --host main
   read -rp 'Workstation snapshot ID: ' SNAP
   restic ls "$SNAP" /etc/ssh
   restic restore "$SNAP" --target "$TARGET/data" --include /etc/ssh
   test -s "$TARGET/data/etc/ssh/ssh_host_ed25519_key"
   ```

3. Before installing, identify the replacement disk and reconcile its
   identifier with `hardware.diskById` in the host registry. Plan the LUKS
   passphrase, Secure Boot signing keys and enrollment. Provision with the
   restored host identity available in the target's `@persist/etc/ssh`
   for activation and first boot. Verify target mounts from the installer.
4. Restore the selected home and system paths from the same snapshot into
   scratch. Copy home contents to the replacement's mounted `@home` and
   persisted files to their declared destinations under `@persist`. Preserve
   owners and modes. Files copied only to an ephemeral root can disappear at
   the next rollback boot.
5. Boot and check sops-dependent services, then reboot and check persistence.
   Open restored projects and applications offline. Record the snapshot ID,
   latest recovered work and time to usability before enabling application sync.

### LUKS passphrase

The LUKS passphrase is not managed by Nix — it was set at install time. Verify a slot is enrolled:

```bash
sudo cryptsetup luksDump /dev/disk/by-id/nvme-eui.0025388401c2aa47-part2 | grep -E 'Keyslot|State'
```

If only the TPM slot is enrolled and TPM fails without initrd SSH available, there is no recovery path. **Keep the passphrase in your external password manager.**
